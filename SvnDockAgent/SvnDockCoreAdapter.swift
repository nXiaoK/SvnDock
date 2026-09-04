import Foundation
import SvnDockCore

/// Shell-free adapter onto SvnDockCore. The cross-process working-copy lock is
/// deliberately held across both the mutation and the full status refresh so
/// Finder never receives a snapshot from the middle of another App operation.
public struct SvnDockCoreCommandExecutor: FinderCommandExecuting, Sendable {
    private static let sharedStateNotification = Notification.Name(
        "com.svndock.shared-state-changed"
    )

    private let builder: SVNCommandBuilder
    private let runner: any ProcessRunning
    private let workingCopyLock: CrossProcessWorkingCopyLock
    private let sharedStore: FinderSharedStore
    private let dirtyMarkers: BadgeRefreshDirtyMarkerStore

    public init(
        baseDirectoryURL: URL,
        executableURL: URL? = nil,
        runner: any ProcessRunning = ProcessRunner()
    ) throws {
        let resolvedExecutable = try executableURL ?? SVNExecutableLocator().locate()
        self.builder = try SVNCommandBuilder(
            executableURL: resolvedExecutable,
            nonInteractive: true
        )
        self.runner = runner
        self.workingCopyLock = try CrossProcessWorkingCopyLock(
            baseDirectoryURL: baseDirectoryURL
        )
        self.sharedStore = try FinderSharedStore(directoryURL: baseDirectoryURL)
        self.dirtyMarkers = try BadgeRefreshDirtyMarkerStore(
            baseDirectoryURL: baseDirectoryURL
        )
    }

    public func execute(_ command: ValidatedFinderCommand) async throws {
        let workingCopy = WorkingCopy(
            id: command.registeredRoot.id,
            name: command.registeredRoot.displayName,
            localPath: command.workingCopyURL
        )
        let operation = try operation(for: command)
        let mutationInvocation = try builder.makeInvocation(
            for: operation,
            in: workingCopy
        )
        let statusInvocation = try builder.makeInvocation(
            for: .status(SVNStatusOptions(
                showRemoteUpdates: false,
                includeIgnored: false,
                paths: []
            )),
            in: workingCopy
        )
        let runner = self.runner
        let sharedStore = self.sharedStore
        let dirtyMarkers = self.dirtyMarkers

        try await workingCopyLock.withLock(for: workingCopy.id) {
            let mutation = try await runner.run(mutationInvocation)
            guard mutation.succeeded else {
                // Output may contain repository paths or credentials, so only
                // the process status crosses the Agent diagnostic boundary.
                throw AgentExecutionError.svnFailed(
                    exitStatus: mutation.terminationStatus
                )
            }

            // From this point onward the mutation is known to have completed.
            // Badge derivation must never turn it into a replayable failure.
            do {
                let status = try await runner.run(statusInvocation)
                guard status.succeeded else {
                    throw BadgeRefreshError.statusFailed
                }
                let entries = try SVNXMLParser.parseStatus(
                    status.standardOutput,
                    workingCopyURL: workingCopy.localPath
                )
                let replacement = Self.badgeEntries(
                    from: entries,
                    in: workingCopy
                )
                try await sharedStore.replaceBadgeEntries(
                    forWorkingCopyID: workingCopy.id,
                    underWorkingCopyRoot: workingCopy.canonicalPath,
                    with: replacement
                )
                try? dirtyMarkers.clear(for: workingCopy.id)
                Self.postSharedStateChanged()
            } catch {
                // One small marker per working copy is overwritten rather than
                // appending an unbounded failure log. A later successful
                // mutation/status pass clears it. Never rethrow here: doing so
                // could replay the already-successful SVN mutation.
                try? dirtyMarkers.markDirty(
                    workingCopyID: workingCopy.id,
                    commandID: command.id
                )
            }
        }
    }

    private func operation(
        for command: ValidatedFinderCommand
    ) throws -> SVNOperationKind {
        let rootPath = command.workingCopyURL.standardizedFileURL.path
        let selectedPaths = command.selectedURLs.map { $0.standardizedFileURL.path }

        switch command.kind {
        case .update:
            guard selectedPaths.count == 1,
                  selectedPaths[0] == rootPath else {
                throw AgentExecutionError.requiresMainApplication(.update)
            }
            return .update(revision: nil)
        case .add:
            return .add(
                paths: selectedPaths,
                parents: true,
                force: false,
                depth: nil
            )
        case .cleanup:
            guard selectedPaths.count == 1,
                  selectedPaths[0] == rootPath else {
                throw AgentExecutionError.requiresMainApplication(.cleanup)
            }
            return .cleanup
        case .openApp, .refresh, .commit, .diff, .revert, .log, .resolve,
             .copyRepositoryURL, .ignoreName, .ignoreExtension:
            throw AgentExecutionError.requiresMainApplication(command.kind)
        }
    }

    private static func badgeEntries(
        from entries: [StatusEntry],
        in workingCopy: WorkingCopy
    ) -> [String: BadgeKind] {
        var replacement: [String: BadgeKind] = [:]
        var rootBadge: BadgeKind?

        for entry in entries where entry.hasLocalChanges {
            let path = entry.fileURL(relativeTo: workingCopy).standardizedFileURL.path
            let badge = BadgeKind(statusEntry: entry)
            replacement[path] = badge
            rootBadge = higherPriority(rootBadge, badge)
        }
        if let rootBadge {
            replacement[workingCopy.canonicalPath] = rootBadge
        }
        return replacement
    }

    private static func higherPriority(_ lhs: BadgeKind?, _ rhs: BadgeKind) -> BadgeKind {
        guard let lhs else { return rhs }
        return badgePriority(rhs) < badgePriority(lhs) ? rhs : lhs
    }

    private static func badgePriority(_ badge: BadgeKind) -> Int {
        switch badge {
        case .conflicted: 0
        case .missing: 1
        case .deleted: 2
        case .replaced: 3
        case .modified: 4
        case .added: 5
        case .unversioned: 6
        case .ignored: 7
        case .clean: 8
        }
    }

    private static func postSharedStateChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            sharedStateNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}

private enum BadgeRefreshError: Error, Sendable {
    case statusFailed
}

private struct BadgeRefreshDirtyMarker: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let workingCopyID: UUID
    let commandID: UUID
    let recordedAt: String

    init(workingCopyID: UUID, commandID: UUID, recordedAt: Date = Date()) {
        self.schemaVersion = Self.currentSchemaVersion
        self.workingCopyID = workingCopyID
        self.commandID = commandID
        self.recordedAt = AgentTimestamp.string(from: recordedAt)
    }
}

/// A bounded, non-sensitive recovery hint. Each working copy owns exactly one
/// fixed-name marker, and every failure atomically replaces that small file.
private struct BadgeRefreshDirtyMarkerStore: @unchecked Sendable {
    private let directoryURL: URL
    private let fileManager: FileManager

    init(
        baseDirectoryURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard baseDirectoryURL.isFileURL,
              baseDirectoryURL.path.hasPrefix("/"),
              baseDirectoryURL.standardizedFileURL.path != "/" else {
            throw AgentQueueStoreError.invalidContainerPath
        }
        self.directoryURL = baseDirectoryURL.standardizedFileURL.appendingPathComponent(
            "badge-refresh-dirty",
            isDirectory: true
        )
        self.fileManager = fileManager
    }

    func markDirty(workingCopyID: UUID, commandID: UUID) throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let marker = BadgeRefreshDirtyMarker(
            workingCopyID: workingCopyID,
            commandID: commandID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(marker).write(to: url(for: workingCopyID), options: [.atomic])
    }

    func clear(for workingCopyID: UUID) throws {
        let markerURL = url(for: workingCopyID)
        guard fileManager.fileExists(atPath: markerURL.path) else { return }
        try fileManager.removeItem(at: markerURL)
    }

    private func url(for workingCopyID: UUID) -> URL {
        directoryURL
            .appendingPathComponent(
                workingCopyID.uuidString.lowercased(),
                isDirectory: false
            )
            .appendingPathExtension("json")
    }
}
