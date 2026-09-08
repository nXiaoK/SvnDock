import Foundation
import SvnDockCore

/// Production service that maps the Foundation-only core into UI values.
/// SVN is invoked directly (never through a shell), and all mutations are
/// serialized per working copy by `WorkingCopyOperationScheduler`.
actor CoreSvnDockService: SvnDockServicing {
    private let sharedStore: FinderSharedStore
    private let executableLocator: SVNExecutableLocator
    private let processRunner: any ProcessRunning
    private let scheduler: WorkingCopyOperationScheduler
    private let crossProcessLock: CrossProcessWorkingCopyLock

    private var coreWorkingCopies: [UUID: SvnDockCore.WorkingCopy] = [:]

    init(
        sharedStore: FinderSharedStore,
        executableLocator: SVNExecutableLocator = SVNExecutableLocator(),
        processRunner: any ProcessRunning = ProcessRunner(),
        scheduler: WorkingCopyOperationScheduler = WorkingCopyOperationScheduler()
    ) throws {
        self.sharedStore = sharedStore
        self.executableLocator = executableLocator
        self.processRunner = processRunner
        self.scheduler = scheduler
        self.crossProcessLock = try CrossProcessWorkingCopyLock(
            baseDirectoryURL: sharedStore.directoryURL
        )
    }

    func loadRegisteredWorkingCopies() async throws -> [SvnDockWorkingCopy] {
        let document = try await sharedStore.loadRegisteredRoots()
        var copies: [SvnDockCore.WorkingCopy] = []
        copies.reserveCapacity(document.roots.count)

        for root in document.roots {
            var copy = SvnDockCore.WorkingCopy(
                id: root.id,
                name: root.displayName,
                localPath: URL(fileURLWithPath: root.path, isDirectory: true),
                isEnabled: root.enabled
            )

            // `registered-roots.json` intentionally stays small and compatible
            // with Finder. Rehydrate repository metadata from the local WC so
            // URLs and revisions remain available after an app restart.
            if root.enabled, let info = try? await loadInfo(for: copy) {
                copy.repositoryURL = info.url
                copy.repositoryRootURL = info.repositoryRootURL
                copy.repositoryUUID = info.repositoryUUID
                copy.revision = info.revision
            }
            copies.append(copy)
        }
        coreWorkingCopies = Dictionary(uniqueKeysWithValues: copies.map { ($0.id, $0) })
        return copies.filter(\.isEnabled).map(makeUIWorkingCopy)
    }

    func registerWorkingCopy(at url: URL) async throws -> SvnDockWorkingCopy {
        let requestedURL = url.standardizedFileURL
        var workingCopy = SvnDockCore.WorkingCopy(localPath: requestedURL)
        var info = try await loadInfo(for: workingCopy)

        if let rootURL = info.workingCopyRootURL {
            let canonicalRoot = rootURL.standardizedFileURL
            if canonicalRoot != requestedURL {
                // `svn info` on a subdirectory describes that subdirectory's
                // URL/revision. Registration always represents the WC root.
                info = try await loadInfo(for: SvnDockCore.WorkingCopy(
                    id: workingCopy.id,
                    localPath: canonicalRoot
                ))
            }
            workingCopy = SvnDockCore.WorkingCopy(
                id: workingCopy.id,
                localPath: canonicalRoot,
                repositoryURL: info.url,
                repositoryRootURL: info.repositoryRootURL,
                repositoryUUID: info.repositoryUUID,
                revision: info.revision
            )
        } else {
            workingCopy.repositoryURL = info.url
            workingCopy.repositoryRootURL = info.repositoryRootURL
            workingCopy.repositoryUUID = info.repositoryUUID
            workingCopy.revision = info.revision
        }

        if let existing = coreWorkingCopies.values.first(where: {
            $0.localPath.standardizedFileURL == workingCopy.localPath.standardizedFileURL
        }) {
            workingCopy = SvnDockCore.WorkingCopy(
                id: existing.id,
                name: existing.name,
                localPath: workingCopy.localPath,
                repositoryURL: workingCopy.repositoryURL,
                repositoryRootURL: workingCopy.repositoryRootURL,
                repositoryUUID: workingCopy.repositoryUUID,
                revision: workingCopy.revision
            )
        }

        _ = try await sharedStore.register(workingCopy)
        coreWorkingCopies[workingCopy.id] = workingCopy
        postSharedStateChanged()
        return makeUIWorkingCopy(workingCopy)
    }

    func unregisterWorkingCopy(id: UUID) async throws {
        _ = try await sharedStore.unregister(id: id)
        let removedCopy = coreWorkingCopies.removeValue(forKey: id)

        if let removedCopy {
            try await removeBadges(
                for: removedCopy.id,
                under: removedCopy.localPath
            )
        }
        postSharedStateChanged()
    }

    func status(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockStatusSnapshot {
        let coreCopy = coreWorkingCopy(for: workingCopy)
        let executableURL = try executableLocator.locate()
        let builder = try SVNCommandBuilder(executableURL: executableURL)
        let invocation = try builder.makeInvocation(
            for: .status(SVNStatusOptions(includeIgnored: true, ignoreExternals: true)),
            in: coreCopy
        )
        let runner = processRunner
        let operationLock = crossProcessLock
        let badgeStore = sharedStore

        // Keep the WC lease through status parsing and badge persistence. If
        // the lock were released immediately after `svn status`, an Agent
        // mutation could publish newer badges and then be overwritten by this
        // stale result.
        let listing = try await scheduler.enqueue(for: coreCopy.id) {
            try await operationLock.withLock(for: coreCopy.id) {
                let result = try await runner.run(invocation)
                guard result.succeeded else {
                    throw SVNProcessFailure(result: result)
                }
                let entries = try SVNXMLParser.parseStatus(
                    result.standardOutput,
                    workingCopyURL: coreCopy.localPath,
                    resolveNodeKinds: false
                )
                let missingInfoByPath = try await Self.missingStatusInfo(
                    for: entries, in: coreCopy, builder: builder, runner: runner
                )
                var badgeWarning: String?
                do {
                    let roots = try await badgeStore.loadRegisteredRoots().roots
                    let excluded = roots.filter { $0.enabled && $0.id != coreCopy.id && Self.path($0.path, isInside: coreCopy.canonicalPath) }.map(\.path)
                    let replacement = FinderBadgeBuilder.build(from: entries, in: coreCopy, excludingRoots: excluded)
                    try await badgeStore.replaceBadgeEntries(
                        forWorkingCopyID: coreCopy.id,
                        underWorkingCopyRoot: coreCopy.localPath.standardizedFileURL.path,
                        with: replacement.entries,
                        directEntries: replacement.directEntries
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A successful SVN status read remains authoritative even
                    // if this optional Finder cache cannot be published.
                    badgeWarning = "本地 SVN 状态已刷新，但 Finder 角标未更新：\(error.localizedDescription)"
                }
                return StatusListingSnapshot(entries: entries, missingInfoByPath: missingInfoByPath,
                                             finderBadgeWarning: badgeWarning)
            }
        }

        let switchedPaths = Set(listing.entries.filter(\.isSwitched).map {
            relativePath(for: $0.fileURL(relativeTo: coreCopy), root: coreCopy.localPath)
        })
        let uiEntries = listing.entries.compactMap { entry -> SvnDockStatusEntry? in
            guard var value = makeUIStatusEntry(
                entry, in: coreCopy,
                missingInfo: entry.status == .missing || entry.status == .deleted
                    ? listing.missingInfoByPath[entry.fileURL(relativeTo: coreCopy).path]
                    : nil
            ) else { return nil }
            var ancestor = value.relativePath
            while true {
                if switchedPaths.contains(ancestor) {
                    value.switchedAncestorPath = ancestor
                    break
                }
                if ancestor == "." { break }
                let parent = (ancestor as NSString).deletingLastPathComponent
                ancestor = parent.isEmpty ? "." : parent
            }
            return value
        }
        postSharedStateChanged()
        return SvnDockStatusSnapshot(entries: uiEntries, finderBadgeWarning: listing.finderBadgeWarning)
    }

    func refreshFinderBadges(for workingCopy: SvnDockWorkingCopy, directoryPaths: [String], preferredPaths: [String] = []) async throws {
        guard !directoryPaths.isEmpty else { return }
        let copy = coreWorkingCopy(for: workingCopy)
        let builder = try SVNCommandBuilder(executableURL: executableLocator.locate())
        let requested = try builder.normalizedLocalPaths(Array(Set(directoryPaths)).sorted().prefix(32).map { $0 }, in: copy, command: "Finder status")
        let runner = processRunner
        let operationLock = crossProcessLock
        let badgeStore = sharedStore
        try await scheduler.enqueue(for: copy.id) {
            try await operationLock.withLock(for: copy.id) {
                let roots = try await badgeStore.loadRegisteredRoots().roots.filter(\.enabled)
                guard roots.contains(where: { $0.id == copy.id && URL(fileURLWithPath: $0.path).standardizedFileURL.path == copy.canonicalPath }) else {
                    throw FinderSharedStoreError.badgeRootNotRegistered(copy.canonicalPath)
                }
                let excluded = roots.filter { $0.id != copy.id && Self.path($0.path, isInside: copy.canonicalPath) }.map(\.path)
                let sparse = try await Self.finderStatus(paths: [], depth: nil, includeUnchanged: false, in: copy, builder: builder, runner: runner)
                var combined = Dictionary(sparse.map { ($0.fileURL(relativeTo: copy).path, $0) }, uniquingKeysWith: { _, latest in latest })
                for directory in requested {
                    try Task.checkCancellation()
                    let url = Self.absoluteURL(for: directory, in: copy)
                    guard !excluded.contains(where: { Self.path(url.path, isInside: $0) }) else { continue }
                    // SVN treats ignored and unversioned directories as opaque.
                    // Never inspect requests below either kind of ancestor.
                    var ancestor = url
                    var opaque = false
                    while Self.path(ancestor.path, isInside: copy.canonicalPath) {
                        if let entry = combined[ancestor.path], entry.status == .ignored || entry.status == .unversioned || entry.status == .external || entry.isFileExternal == true {
                            opaque = true
                            break
                        }
                        if ancestor.path == copy.canonicalPath { break }
                        ancestor.deleteLastPathComponent()
                    }
                    guard !opaque else { continue }
                    // Invalid observation hints do not stop valid windows from
                    // refreshing. Check the metadata before issuing status.
                    guard (try? Self.validatedFinderPath(directory, in: copy)) != nil,
                          (try? Self.validatedDirectoryURL(for: directory, in: copy)) != nil else { continue }
                    let infoResult = try await runner.run(builder.makeInvocation(for: .infoTargets(paths: [directory]), in: copy))
                    guard infoResult.succeeded,
                          let infos = try? SVNXMLParser.parseInfos(infoResult.standardOutput),
                          let info = infos.first(where: { Self.absoluteURL(for: $0.path, in: copy) == url }),
                          info.kind == .directory,
                          Self.belongsToWorkingCopy(info, copy: copy) else { continue }
                    let immediate = try await Self.finderStatus(paths: [directory], depth: .immediates, includeUnchanged: true, in: copy, builder: builder, runner: runner)
                    _ = try Self.validatedFinderPath(directory, in: copy)
                    for entry in immediate {
                        let path = entry.fileURL(relativeTo: copy).path
                        // Depth is also enforced when parsing, so malformed or
                        // unexpectedly recursive output cannot expand the scope.
                        guard path == url.path || URL(fileURLWithPath: path).deletingLastPathComponent() == url else { continue }
                        combined[path] = entry
                    }
                }
                let preferred = preferredPaths.filter { path in
                    requested.contains { Self.absoluteURL(for: $0, in: copy).path == URL(fileURLWithPath: path).deletingLastPathComponent().path }
                }.prefix(2_048).map { $0 }
                let badges = FinderBadgeBuilder.build(from: Array(combined.values), in: copy, excludingRoots: excluded, preferredPaths: preferred)
                try await badgeStore.replaceBadgeEntries(forWorkingCopyID: copy.id,
                    underWorkingCopyRoot: copy.canonicalPath, with: badges.entries, directEntries: badges.directEntries)
            }
        }
        postSharedStateChanged()
    }

    func finderTarget(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> SvnDockFinderTarget {
        let copy = coreWorkingCopy(for: workingCopy)
        let builder = try SVNCommandBuilder(executableURL: executableLocator.locate())
        let target = try builder.normalizedLocalPaths([relativePath], in: copy, command: "Finder target")[0]
        let runner = processRunner
        let operationLock = crossProcessLock
        let pair = try await scheduler.enqueue(for: copy.id) {
            try await operationLock.withLock(for: copy.id) {
                _ = try Self.validatedFinderPath(target, in: copy)
                let result = try await runner.run(builder.makeInvocation(for: .infoTargets(paths: [target]), in: copy))
                guard result.succeeded else {
                    throw SvnDockServiceError.unavailable("所选项目没有当前工作副本中的版本记录，请刷新 Finder 后重试。")
                }
                let infos = try SVNXMLParser.parseInfos(result.standardOutput)
                guard let info = infos.first(where: { Self.absoluteURL(for: $0.path, in: copy) == Self.absoluteURL(for: target, in: copy) }),
                      Self.belongsToWorkingCopy(info, copy: copy) else {
                    throw SvnDockServiceError.unavailable("所选项目属于其它工作副本，请从所属工作副本打开。")
                }
                let entries = try await Self.finderStatus(paths: [target], depth: .empty, includeUnchanged: true, in: copy, builder: builder, runner: runner)
                guard let entry = Self.statusEntry(for: target, entries: entries, in: copy),
                      entry.status != .unversioned, entry.status != .ignored, entry.status != .external,
                      entry.status != .none, entry.isFileExternal != true else {
                    throw SvnDockServiceError.unavailable("所选项目没有可查看的 SVN 版本记录，请刷新 Finder 后重试。")
                }
                if case .unknown = entry.status {
                    throw SvnDockServiceError.unavailable("无法确认所选项目的 SVN 状态，请刷新后重试。")
                }
                _ = try Self.validatedFinderPath(target, in: copy)
                return (entry, info)
            }
        }
        let entry = pair.0
        let info = pair.1
        let effectiveStatus: SvnDockStatusKind = entry.isTreeConflicted || entry.status == .conflicted || entry.propertyStatus == .conflicted
            ? .conflicted : (entry.status == .normal && entry.propertyStatus.isLocalChange ? .modified : mapStatus(entry.status))
        let value = SvnDockStatusEntry(workingCopyID: copy.id, relativePath: target,
            nodeKind: info.kind == .directory ? .directory : .file, status: effectiveStatus,
            conflictKinds: conflictKinds(for: entry), changelist: entry.changelist,
            workingCopySchedule: info.schedule, workingCopyRevision: entry.revision)
        var repositoryPath: String?
        if let url = info.url, let root = info.repositoryRootURL,
           url.scheme == root.scheme, url.host == root.host, url.port == root.port,
           url.pathComponents.starts(with: root.pathComponents) {
            repositoryPath = "/" + url.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
        }
        return SvnDockFinderTarget(entry: value, repositoryRelativePath: repositoryPath)
    }

    private static func finderStatus(paths: [String], depth: SVNDepth?, includeUnchanged: Bool,
                                     in copy: SvnDockCore.WorkingCopy, builder: SVNCommandBuilder,
                                     runner: any ProcessRunning) async throws -> [SvnDockCore.StatusEntry] {
        let result = try await runner.run(builder.makeInvocation(for: .status(SVNStatusOptions(
            includeIgnored: true, includeUnchanged: includeUnchanged, ignoreExternals: true, depth: depth, paths: paths)), in: copy))
        guard result.succeeded else { throw SVNProcessFailure(result: result) }
        // Bound parsing and snapshot growth even for one enormous directory.
        guard result.standardOutput.count <= 16 * 1_024 * 1_024 else { throw CocoaError(.fileReadTooLarge) }
        return try SVNXMLParser.parseStatus(result.standardOutput, workingCopyURL: copy.localPath, resolveNodeKinds: false)
    }

    private static func belongsToWorkingCopy(_ info: SVNInfo, copy: SvnDockCore.WorkingCopy) -> Bool {
        info.workingCopyRootURL?.resolvingSymlinksInPath().standardizedFileURL == copy.localPath.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func validatedFinderPath(_ path: String, in copy: SvnDockCore.WorkingCopy) throws -> URL {
        try validateResolvedBoundary(relativePaths: [path], in: copy)
        let target = absoluteURL(for: path, in: copy)
        let relative = target.pathComponents.dropFirst(copy.localPath.standardizedFileURL.pathComponents.count).joined(separator: "/")
        let expected = copy.localPath.resolvingSymlinksInPath().appendingPathComponent(relative).standardizedFileURL
        guard target.resolvingSymlinksInPath().standardizedFileURL == expected else {
            throw SvnDockServiceError.unavailable("Finder 所选路径经过符号链接，请直接打开工作副本内的原始路径。")
        }
        return target
    }

    func refreshWorkingCopyMetadata(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockWorkingCopy {
        var copy = coreWorkingCopy(for: workingCopy)
        let info = try await loadInfo(for: copy)
        copy.repositoryURL = info.url
        copy.repositoryRootURL = info.repositoryRootURL
        copy.repositoryUUID = info.repositoryUUID
        copy.revision = info.revision
        // Do not resurrect a registration removed while the read was running.
        if coreWorkingCopies[copy.id]?.localPath == copy.localPath {
            coreWorkingCopies[copy.id] = copy
        }
        return makeUIWorkingCopy(copy)
    }

    func checkRemoteStatus(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockRemoteStatusSnapshot {
        let coreCopy = coreWorkingCopy(for: workingCopy)
        let result = try await run(.status(SVNStatusOptions(showRemoteUpdates: true)), in: coreCopy)
        let entries = try SVNXMLParser.parseStatus(
            result.standardOutput, workingCopyURL: coreCopy.localPath, resolveNodeKinds: false
        )
        let changes = entries.compactMap { entry -> SvnDockRemoteStatusEntry? in
            let status = entry.repositoryStatus ?? .none
            let property = entry.repositoryPropertyStatus ?? .none
            let contentChanged = status != .normal && status != .none
            let propertiesChanged = property != .normal && property != .none
            guard contentChanged || propertiesChanged else { return nil }
            return SvnDockRemoteStatusEntry(
                relativePath: relativePath(for: entry.fileURL(relativeTo: coreCopy), root: coreCopy.localPath),
                status: mapStatus(status), propertiesChanged: propertiesChanged
            )
        }
        return SvnDockRemoteStatusSnapshot(entries: changes)
    }

    func directoryChildren(
        relativePath: String,
        in workingCopy: SvnDockWorkingCopy
    ) async throws -> [SvnDockStatusEntry] {
        let coreCopy = coreWorkingCopy(for: workingCopy)
        let executableURL = try executableLocator.locate()
        let builder = try SVNCommandBuilder(executableURL: executableURL)
        let invocation = try builder.makeInvocation(
            for: .status(SVNStatusOptions(
                includeIgnored: true,
                depth: .immediates,
                paths: [relativePath]
            )),
            in: coreCopy
        )
        let runner = processRunner
        let operationLock = crossProcessLock

        let listing = try await scheduler.enqueue(for: coreCopy.id) {
            try await operationLock.withLock(for: coreCopy.id) {
                let directoryURL = try Self.validatedDirectoryURL(
                    for: relativePath,
                    in: coreCopy
                )
                let diskChildren = try Self.immediateDiskChildren(
                    of: directoryURL,
                    in: coreCopy
                )

                let result = try await runner.run(invocation)
                guard result.succeeded else {
                    throw SVNProcessFailure(result: result)
                }
                let statusEntries = try SVNXMLParser.parseStatus(
                    result.standardOutput,
                    workingCopyURL: coreCopy.localPath,
                    resolveNodeKinds: false
                )
                let missingInfoByPath = try await Self.missingStatusInfo(
                    for: statusEntries, in: coreCopy, builder: builder, runner: runner
                )

                // Discard the snapshot if the directory was replaced by a
                // symlink while it was being read. The filesystem is not
                // covered by our cooperative working-copy lock.
                _ = try Self.validatedDirectoryURL(
                    for: relativePath,
                    in: coreCopy
                )
                return DirectoryListingSnapshot(
                    directoryURL: directoryURL,
                    diskChildren: diskChildren,
                    statusEntries: statusEntries,
                    missingInfoByPath: missingInfoByPath
                )
            }
        }

        return makeUIDirectoryChildren(listing, in: coreCopy)
    }

    func diff(
        relativePath: String,
        in workingCopy: SvnDockWorkingCopy
    ) async throws -> String {
        let coreCopy = coreWorkingCopy(for: workingCopy)
        let result = try await run(.diff(paths: [relativePath], depth: .empty), in: coreCopy)
        return result.standardOutputString
    }

    func classifyLocalDifference(
        relativePath: String,
        in workingCopy: SvnDockWorkingCopy
    ) async throws -> SVNLocalDifferenceKind {
        let copy = coreWorkingCopy(for: workingCopy)
        let builder = try SVNCommandBuilder(executableURL: executableLocator.locate())
        let target = try builder.normalizedLocalPaths([relativePath], in: copy, command: "diff")[0]
        let runner = processRunner
        let operationLock = crossProcessLock
        return try await scheduler.enqueue(for: copy.id) {
            try await operationLock.withLock(for: copy.id) {
                try await Self.classifyLocalDifference(target: target, in: copy, builder: builder, runner: runner)
            }
        }
    }

    private static func classifyLocalDifference(
        target: String, in copy: SvnDockCore.WorkingCopy,
        builder: SVNCommandBuilder, runner: any ProcessRunning
    ) async throws -> SVNLocalDifferenceKind {
        // Classify one regular text file at a time. Unknown states must remain
        // visible, including symlinks, nested WCs and files being rewritten.
        let file = try validatedFinderPath(target, in: copy)
        guard let before = try localDifferenceFingerprint(file) else { return .unknown }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: localDifferenceFileLimit + 1) ?? Data()
        guard bytes.count <= localDifferenceFileLimit, !bytes.contains(0),
              String(data: bytes, encoding: .utf8) != nil else { return .unknown }

        func execute(_ operation: SVNOperationKind) async throws -> ProcessResult {
            try Task.checkCancellation()
            let invocation = try builder.makeInvocation(for: operation, in: copy)
            let result = try await runner.run(ProcessInvocation(
                executableURL: invocation.executableURL, arguments: invocation.arguments,
                currentDirectoryURL: invocation.currentDirectoryURL, environment: invocation.environment,
                standardInput: invocation.standardInput, argumentFiles: invocation.argumentFiles,
                outputByteLimit: 8 * 1_024 * 1_024
            ))
            guard result.succeeded else { throw SVNProcessFailure(result: result) }
            return result
        }
        func currentStatus() async throws -> SvnDockCore.StatusEntry? {
            let result = try await execute(.status(SVNStatusOptions(
                includeIgnored: true, includeUnchanged: true, ignoreExternals: true,
                depth: .empty, paths: [target]
            )))
            guard result.standardError.isEmpty else { return nil }
            return statusEntry(for: target, entries: try SVNXMLParser.parseStatus(
                result.standardOutput, workingCopyURL: copy.localPath, resolveNodeKinds: false
            ), in: copy)
        }
        guard let status = try await currentStatus() else { return .unknown }
        if case .unknown = status.status { return .unknown }
        if case .unknown = status.propertyStatus { return .unknown }
        guard status.status == .modified,
              status.propertyStatus == .none || status.propertyStatus == .normal,
              !status.isCopied, !status.isSwitched, status.isFileExternal != true,
              !status.isTreeConflicted, (status.revision ?? -1) >= 0 else { return .substantive }
        let infoResult = try await execute(.infoTargets(paths: [target]))
        guard infoResult.standardError.isEmpty else { return .unknown }
        let info = try SVNXMLParser.parseInfo(infoResult.standardOutput)
        guard info.kind == .file, info.schedule == "normal", belongsToWorkingCopy(info, copy: copy) else {
            return .substantive
        }

        let eolDiff = try await execute(.localDifference(relativePath: target, ignoringWhitespace: false))
        guard eolDiff.standardError.isEmpty else { return .unknown }
        let classification: SVNLocalDifferenceKind
        if eolDiff.standardOutput.isEmpty {
            // A stale or translated status can have no actual diff. Do not
            // label that as an EOL edit without an ordinary text hunk.
            let original = try await execute(.diff(paths: [target], depth: .empty))
            guard original.standardError.isEmpty,
                  original.standardOutputString.split(separator: "\n").contains(where: { $0.hasPrefix("@@ -") }) else {
                return .unknown
            }
            classification = .lineEndingsOnly
        } else {
            let whitespaceDiff = try await execute(.localDifference(relativePath: target, ignoringWhitespace: true))
            guard whitespaceDiff.standardError.isEmpty else { return .unknown }
            classification = whitespaceDiff.standardOutput.isEmpty ? .whitespaceOnly : .substantive
        }
        guard classification != .substantive else { return classification }
        try Task.checkCancellation()
        guard try validatedFinderPath(target, in: copy) == file,
              try localDifferenceFingerprint(file) == before,
              try await currentStatus() == status else { return .unknown }
        return classification
    }

    private static let localDifferenceFileLimit = 2 * 1_024 * 1_024

    private static func localDifferenceFingerprint(_ file: URL) throws -> LocalDifferenceFingerprint? {
        let values = try FileManager.default.attributesOfItem(atPath: file.path)
        guard values[.type] as? FileAttributeType == .typeRegular,
              let size = values[.size] as? NSNumber, size.int64Value <= Int64(localDifferenceFileLimit),
              let date = values[.modificationDate] as? Date,
              let inode = values[.systemFileNumber] as? NSNumber else { return nil }
        return LocalDifferenceFingerprint(size: size.int64Value, modificationDate: date, inode: inode.uint64Value)
    }

    private struct LocalDifferenceFingerprint: Equatable {
        let size: Int64
        let modificationDate: Date
        let inode: UInt64
    }

    func history(
        for workingCopy: SvnDockWorkingCopy,
        relativePaths: [String],
        limit: Int
    ) async throws -> [SvnDockLogEntry] {
        try await historyPage(for: workingCopy, relativePaths: relativePaths, limit: limit, beforeRevision: nil)
    }

    func historyPage(
        for workingCopy: SvnDockWorkingCopy,
        relativePaths: [String],
        limit: Int,
        beforeRevision: Int?
    ) async throws -> [SvnDockLogEntry] {
        let coreCopy = coreWorkingCopy(for: workingCopy)
        if let beforeRevision, beforeRevision <= 1 {
            guard beforeRevision >= 0 else { throw SVNCommandBuilderError.invalidRevision(beforeRevision) }
            // The first real SVN revision has no earlier page. Validate the
            // remaining inputs before returning, without launching a process.
            let builder = try SVNCommandBuilder(executableURL: executableLocator.locate())
            _ = try builder.makeInvocation(for: .log(paths: relativePaths, limit: limit), in: coreCopy)
            return []
        }
        let result = try await run(
            .log(paths: relativePaths, limit: limit, beforeRevision: beforeRevision), in: coreCopy
        )
        return try SVNXMLParser.parseLog(result.standardOutput).map {
            SvnDockLogEntry(
                revision: $0.revision,
                author: $0.author,
                date: $0.date,
                message: $0.message
            )
        }
    }

    func revisionDetails(revision: Int, in workingCopy: SvnDockWorkingCopy) async throws -> SVNRevisionDetails {
        let copy = coreWorkingCopy(for: workingCopy)
        let info = try await loadInfo(for: copy)
        guard let root = info.repositoryRootURL else {
            throw SvnDockServiceError.unavailable("无法确定该工作副本的仓库根地址。")
        }
        let log = try await run(.revisionLog(repositoryRoot: root, revision: revision), in: copy)
        guard let entry = try SVNXMLParser.parseLog(log.standardOutput).first,
              entry.revision == revision else {
            throw SvnDockServiceError.unavailable("无法读取 r\(revision)，该版本可能不存在或当前账号无权访问。")
        }
        try Task.checkCancellation()
        let summary = try await run(.revisionSummary(repositoryRoot: root, revision: revision), in: copy)
        var details = try SVNRevisionDetails.combining(
            repositoryRootURL: root, entry: entry,
            summary: SVNXMLParser.parseDiffSummary(summary.standardOutput)
        )
        for directory in details.deletedCopyDirectoriesToExpand {
            try Task.checkCancellation()
            let descendants = try await run(
                .revisionCopyDeletionSummary(repositoryRoot: root, revision: revision, change: directory), in: copy
            )
            details = try details.addingDeletedCopyDescendants(
                SVNXMLParser.parseDiffSummary(descendants.standardOutput), of: directory
            )
        }
        return details
    }

    func revisionDiff(revision: Int, change: SVNChangedPath, repositoryRoot: URL,
                      in workingCopy: SvnDockWorkingCopy) async throws -> String {
        let result = try await run(
            .revisionDiff(repositoryRoot: repositoryRoot, revision: revision, change: change),
            in: coreWorkingCopy(for: workingCopy)
        )
        return result.standardOutputString
    }

    func update(workingCopies: [SvnDockWorkingCopy]) async throws {
        for copy in workingCopies {
            let coreCopy = coreWorkingCopy(for: copy)
            _ = try await run(.update(revision: nil), in: coreCopy)
        }
    }

    func commit(
        workingCopy: SvnDockWorkingCopy,
        relativePaths: [String],
        message: String
    ) async throws {
        guard workingCopy.repositoryURL != nil, workingCopy.repositoryUUID != nil else {
            throw SVNSelectedCommitError.repositoryIdentityChanged
        }
        let coreCopy = SvnDockCore.WorkingCopy(id: workingCopy.id, name: workingCopy.name,
            localPath: workingCopy.rootURL, repositoryURL: workingCopy.repositoryURL,
            repositoryUUID: workingCopy.repositoryUUID, revision: workingCopy.revision)
        let commit = try SVNSelectedCommit(executableURL: executableLocator.locate(), runner: processRunner)
        let targets = try commit.targets(for: relativePaths, in: coreCopy)
        let operationLock = crossProcessLock
        try await scheduler.enqueue(for: coreCopy.id) {
            try await operationLock.withLock(for: coreCopy.id) {
                try Self.validateResolvedBoundary(relativePaths: targets, in: coreCopy)
                try await commit.run(targets: targets, message: message, in: coreCopy)
            }
        }
    }

    func add(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws {
        let coreCopy = coreWorkingCopy(for: workingCopy)
        _ = try await run(
            .add(
                paths: relativePaths,
                parents: true,
                force: true,
                depth: nil
            ),
            in: coreCopy
        )
    }

    func unscheduleAdd(
        relativePaths: [String],
        in workingCopy: SvnDockWorkingCopy
    ) async throws {
        try await undoAddition(relativePaths: relativePaths, in: workingCopy, missingOnly: false)
    }

    func cleanupMissingAdditions(
        relativePaths: [String],
        in workingCopy: SvnDockWorkingCopy
    ) async throws {
        try await undoAddition(relativePaths: relativePaths, in: workingCopy, missingOnly: true)
    }

    func scheduleMissingDeletion(
        relativePaths: [String],
        in workingCopy: SvnDockWorkingCopy
    ) async throws {
        let coreCopy = coreWorkingCopy(for: workingCopy)
        let deletion = try SVNMissingDeletion(executableURL: executableLocator.locate(), runner: processRunner)
        let targets = try deletion.targets(for: relativePaths, in: coreCopy)
        let operationLock = crossProcessLock
        try await scheduler.enqueue(for: coreCopy.id) {
            try await operationLock.withLock(for: coreCopy.id) {
                try Task.checkCancellation()
                try Self.validateResolvedBoundary(relativePaths: targets, in: coreCopy)
                try await deletion.run(targets: targets, in: coreCopy)
            }
        }
    }

    private func undoAddition(
        relativePaths: [String],
        in workingCopy: SvnDockWorkingCopy,
        missingOnly: Bool
    ) async throws {
        let coreCopy = coreWorkingCopy(for: workingCopy)
        let undo = try SVNAdditionUndo(executableURL: executableLocator.locate(), runner: processRunner)
        let targets = try undo.targets(for: relativePaths, in: coreCopy)
        let operationLock = crossProcessLock
        try await scheduler.enqueue(for: coreCopy.id) {
            try await operationLock.withLock(for: coreCopy.id) {
                try Task.checkCancellation()
                try Self.validateResolvedBoundary(
                    relativePaths: targets,
                    in: coreCopy
                )
                try await undo.run(targets: targets, in: coreCopy, missingOnly: missingOnly)
            }
        }
    }

    func revert(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws {
        let coreCopy = coreWorkingCopy(for: workingCopy)
        let builder = try SVNCommandBuilder(executableURL: executableLocator.locate())
        let targets = Array(Set(try builder.normalizedLocalPaths(relativePaths, in: coreCopy))).sorted()
        let runner = processRunner
        let operationLock = crossProcessLock
        try await scheduler.enqueue(for: coreCopy.id) {
            try await operationLock.withLock(for: coreCopy.id) {
                try Self.validateResolvedBoundary(relativePaths: targets, in: coreCopy)
                let groups = try await Self.revertTargetGroups(
                    targets, in: coreCopy, builder: builder, runner: runner
                )
                var completedPaths: [String] = []
                do {
                    for (paths, depth) in groups where !paths.isEmpty {
                        try Task.checkCancellation()
                        try Self.validateResolvedBoundary(relativePaths: paths, in: coreCopy)
                        let result = try await runner.run(builder.makeInvocation(
                            for: .revert(paths: paths, depth: depth), in: coreCopy
                        ))
                        guard result.succeeded else { throw SVNProcessFailure(result: result) }
                        completedPaths.append(contentsOf: paths)
                    }
                } catch {
                    let completed = Set(completedPaths)
                    throw SvnDockRevertFailure(completedPaths: completedPaths,
                        unconfirmedPaths: groups.flatMap { $0.0 }.filter { !completed.contains($0) },
                        wasCancelled: error is CancellationError, detail: error.localizedDescription)
                }
            }
        }
    }

    private static func revertTargetGroups(
        _ targets: [String], in workingCopy: SvnDockCore.WorkingCopy,
        builder: SVNCommandBuilder, runner: any ProcessRunning
    ) async throws -> [([String], SVNDepth)] {
        var statuses: [String: SvnDockCore.StatusEntry] = [:]
        var start = 0
        // Status does not support --targets. Bound both the number of arguments
        // and their bytes while checking the full selection before any revert.
        while start < targets.count {
            var end = start
            var bytes = 0
            while end < targets.count && end - start < 256 {
                let size = targets[end].utf8.count + 1
                if end > start && bytes + size > 64_000 { break }
                bytes += size
                end += 1
            }
            try Task.checkCancellation()
            let result = try await runner.run(builder.makeInvocation(
                for: .status(SVNStatusOptions(depth: .empty, paths: Array(targets[start..<end]))),
                in: workingCopy
            ))
            guard result.succeeded else { throw SVNProcessFailure(result: result) }
            for entry in try SVNXMLParser.parseStatus(
                result.standardOutput, workingCopyURL: workingCopy.localPath, resolveNodeKinds: false
            ) {
                statuses[absoluteURL(for: entry.path, in: workingCopy).path] = entry
            }
            start = end
        }

        let candidates = targets.filter {
            let status = statuses[absoluteURL(for: $0, in: workingCopy).path]?.status
            return status == .missing || status == .deleted
        }
        var recursive = Set<String>()
        if !candidates.isEmpty {
            try Task.checkCancellation()
            let result = try await runner.run(builder.makeInvocation(
                for: .infoTargets(paths: candidates), in: workingCopy
            ))
            guard result.succeeded else { throw SVNProcessFailure(result: result) }
            let infos = try SVNXMLParser.parseInfos(result.standardOutput)
            let infoByPath = Dictionary(infos.map {
                (absoluteURL(for: $0.path, in: workingCopy).path, $0)
            }, uniquingKeysWith: { _, latest in latest })
            for target in candidates {
                let path = absoluteURL(for: target, in: workingCopy).path
                guard let info = infoByPath[path], info.kind == .directory else { continue }
                let status = statuses[path]?.status
                // Recursive restore is necessary for an absent/deleted tree.
                // Property-only directories and paths whose schedule changed
                // must remain shallow to preserve unrelated child edits.
                if (status == .missing && info.schedule == "normal")
                    || (status == .deleted && info.schedule == "delete") {
                    guard info.workingCopyRootURL?.resolvingSymlinksInPath().standardizedFileURL
                        == workingCopy.localPath.resolvingSymlinksInPath().standardizedFileURL else {
                        throw SvnDockServiceError.unavailable("无法确认“\(target)”属于当前工作副本，请刷新后重试。")
                    }
                    recursive.insert(target)
                }
            }
        }

        let independentTargets = targets.filter { target in
            if target != "." && recursive.contains(".") { return false }
            var parent = (target as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if recursive.contains(parent) { return false }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }
        return [
            (independentTargets.filter { recursive.contains($0) }, .infinity),
            (independentTargets.filter { !recursive.contains($0) }, .empty)
        ]
    }

    func resolve(
        relativePaths: [String],
        using resolution: SvnDockConflictResolution,
        in workingCopy: SvnDockWorkingCopy
    ) async throws {
        let coreCopy = coreWorkingCopy(for: workingCopy)
        let choice: SVNConflictChoice = switch resolution {
        case .working: .working
        case .mineFull: .mineFull
        case .theirsFull: .theirsFull
        case .base: .base
        }
        let executableURL = try executableLocator.locate()
        let builder = try SVNCommandBuilder(executableURL: executableURL)
        let targets = Array(Set(try builder.normalizedLocalPaths(relativePaths, in: coreCopy, command: "resolve"))).sorted()
        let statusInvocation = try builder.makeInvocation(
            for: .status(SVNStatusOptions(depth: .empty, paths: targets)),
            in: coreCopy
        )
        let infoInvocation = try builder.makeInvocation(for: .infoTargets(paths: targets), in: coreCopy)
        let resolveInvocation = try builder.makeInvocation(
            for: .resolve(paths: targets, accept: choice),
            in: coreCopy
        )
        let runner = processRunner
        let operationLock = crossProcessLock

        try await scheduler.enqueue(for: coreCopy.id) {
            try await operationLock.withLock(for: coreCopy.id) {
                try Self.validateResolvedBoundary(
                    relativePaths: targets,
                    in: coreCopy
                )

                let statusResult = try await runner.run(statusInvocation)
                guard statusResult.succeeded else {
                    throw SVNProcessFailure(result: statusResult)
                }
                let currentEntries = try SVNXMLParser.parseStatus(
                    statusResult.standardOutput,
                    workingCopyURL: coreCopy.localPath
                )
                try Self.validateConflictTargets(
                    targets,
                    resolution: resolution,
                    entries: currentEntries,
                    in: coreCopy
                )
                try Self.validateConflictReplacementFiles(targets, resolution: resolution, in: coreCopy)
                // A path inside this directory may be a nested checkout or an
                // external. Its own WC root must match before changing state.
                let infoResult = try await runner.run(infoInvocation)
                guard infoResult.succeeded else { throw SVNProcessFailure(result: infoResult) }
                let infos = try SVNXMLParser.parseInfos(infoResult.standardOutput)
                let root = coreCopy.localPath.resolvingSymlinksInPath().standardizedFileURL
                for target in targets {
                    guard let info = infos.first(where: {
                        Self.absoluteURL(for: $0.path, in: coreCopy) == Self.absoluteURL(for: target, in: coreCopy)
                    }), info.workingCopyRootURL?.resolvingSymlinksInPath().standardizedFileURL == root else {
                        throw SvnDockServiceError.unavailable("无法确认“\(target)”属于当前工作副本，请单独打开所属工作副本后处理冲突。")
                    }
                }

                // Resolve symlinks again immediately before the mutation. The
                // confirmation dialog may have remained open for an arbitrary
                // amount of time after Finder originally queued the request.
                try Self.validateResolvedBoundary(
                    relativePaths: targets,
                    in: coreCopy
                )
                try Self.validateConflictReplacementFiles(targets, resolution: resolution, in: coreCopy)
                let resolveResult = try await runner.run(resolveInvocation)
                guard resolveResult.succeeded else {
                    throw SVNProcessFailure(result: resolveResult)
                }
                let verifiedEntries: [SvnDockCore.StatusEntry]
                do {
                    try Self.validateResolvedBoundary(relativePaths: targets, in: coreCopy)
                    let verification = try await runner.run(statusInvocation)
                    guard verification.succeeded else { throw SVNProcessFailure(result: verification) }
                    verifiedEntries = try SVNXMLParser.parseStatus(
                        verification.standardOutput, workingCopyURL: coreCopy.localPath
                    )
                } catch {
                    throw SvnDockResolveVerificationError.statusUnavailable(
                        detail: error is CancellationError ? "状态核验已取消。" : error.localizedDescription
                    )
                }
                let remaining = targets.filter { target in
                    guard let entry = Self.statusEntry(for: target, entries: verifiedEntries, in: coreCopy) else { return false }
                    return entry.status == .conflicted || entry.propertyStatus == .conflicted || entry.isTreeConflicted
                }
                guard remaining.isEmpty else {
                    throw SvnDockResolveVerificationError.remainingConflicts(paths: remaining)
                }
            }
        }
    }

    func prepareIgnoreRecommendations(in workingCopy: SvnDockWorkingCopy) async throws -> SvnDockIgnoreRecommendationPlan {
        let copy = coreWorkingCopy(for: workingCopy)
        let builder = try SVNCommandBuilder(executableURL: executableLocator.locate())
        let runner = processRunner
        let operationLock = crossProcessLock
        return try await scheduler.enqueue(for: copy.id) {
            try await operationLock.withLock(for: copy.id) {
                try await Self.ignoreRecommendations(in: workingCopy, coreCopy: copy, builder: builder, runner: runner)
            }
        }
    }

    func applyIgnoreRecommendations(_ plan: SvnDockIgnoreRecommendationPlan, selectedIDs: Set<String>) async throws {
        guard !selectedIDs.isEmpty, selectedIDs.isSubset(of: Set(plan.items.map(\.id))) else {
            throw SvnDockServiceError.invalidIgnoreTarget("请选择本次扫描得到的忽略项。")
        }
        let rules = plan.items.filter { selectedIDs.contains($0.id) }.map(\.rule)
        try await performIgnoreRules(rules, in: plan.workingCopy, recommendationPlan: plan)
    }

    private static func ignoreRecommendations(in workingCopy: SvnDockWorkingCopy,
        coreCopy: SvnDockCore.WorkingCopy, builder: SVNCommandBuilder,
        runner: any ProcessRunning) async throws -> SvnDockIgnoreRecommendationPlan {
        let infoResult = try await runner.run(builder.makeInvocation(for: .info, in: coreCopy))
        guard infoResult.succeeded else { throw SVNProcessFailure(result: infoResult) }
        let info = try SVNXMLParser.parseInfo(infoResult.standardOutput)
        guard let url = workingCopy.repositoryURL, let uuid = workingCopy.repositoryUUID,
              info.url == url, info.repositoryUUID == uuid,
              info.workingCopyRootURL?.resolvingSymlinksInPath().standardizedFileURL.path
                == workingCopy.rootURL.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw SvnDockServiceError.invalidIgnoreTarget("工作副本地址或身份已变化。请刷新工作副本并重新扫描，未添加忽略规则。")
        }
        let result = try await runner.run(builder.makeInvocation(for: .status(SVNStatusOptions(
            includeIgnored: true, includeUnchanged: true, ignoreExternals: true)), in: coreCopy))
        guard result.succeeded else { throw SVNProcessFailure(result: result) }
        let statuses = try SVNXMLParser.parseStatus(result.standardOutput, workingCopyURL: coreCopy.localPath, resolveNodeKinds: false)
        return try SvnDockIgnoreRecommendationScanner.scan(in: workingCopy, statuses: statuses)
    }

    func addIgnoreRules(
        _ rules: [SvnDockIgnoreRule],
        in workingCopy: SvnDockWorkingCopy
    ) async throws {
        try await performIgnoreRules(rules, in: workingCopy, recommendationPlan: nil)
    }

    private func performIgnoreRules(_ rules: [SvnDockIgnoreRule], in workingCopy: SvnDockWorkingCopy,
                                   recommendationPlan: SvnDockIgnoreRecommendationPlan?) async throws {
        guard !rules.isEmpty else { return }

        for rule in rules {
            try Self.validateIgnoreRuleShape(rule)
        }

        let coreCopy = coreWorkingCopy(for: workingCopy)
        let executableURL = try executableLocator.locate()
        let builder = try SVNCommandBuilder(executableURL: executableURL)
        let runner = processRunner
        let operationLock = crossProcessLock
        let groupedRules = Dictionary(grouping: rules, by: \.parentRelativePath)

        try await scheduler.enqueue(for: coreCopy.id) {
            try await operationLock.withLock(for: coreCopy.id) {
                if let recommendationPlan {
                    // Recheck the whole selection under the same lease as the
                    // writes. A stale scan must not hide newly versioned files.
                    let fresh = try await Self.ignoreRecommendations(in: recommendationPlan.workingCopy,
                        coreCopy: coreCopy, builder: builder, runner: runner)
                    let available = Set(fresh.items.map(\.rule))
                    guard rules.allSatisfy({ available.contains($0) }) else {
                        throw SvnDockServiceError.invalidIgnoreTarget("推荐项的状态或项目结构已变化，请重新扫描。未添加任何规则。")
                    }
                }
                for parentPath in groupedRules.keys.sorted() {
                    try Task.checkCancellation()
                    guard let rulesForParent = groupedRules[parentPath] else { continue }

                    let targetPaths = rulesForParent.map(\.targetRelativePath)
                    try Self.validateResolvedBoundary(
                        relativePaths: [parentPath] + targetPaths,
                        in: coreCopy
                    )

                    if recommendationPlan != nil {
                        let root = coreCopy.localPath.resolvingSymlinksInPath().standardizedFileURL
                        let parent = parentPath == "." ? root : root.appendingPathComponent(parentPath)
                        guard SvnDockIgnoreRecommendationScanner.safeDirectory(parent, root: root) else {
                            throw SvnDockServiceError.invalidIgnoreTarget("忽略目标父目录已变为符号链接或外部工作副本，请重新扫描。")
                        }
                    }

                    // svn:ignore can only be stored on a versioned directory.
                    // Always schedule only the parent chain. Status can return
                    // an empty target for a directory nested below an
                    // unversioned ancestor, so it cannot reliably distinguish
                    // that case from a clean versioned directory. `--force`
                    // makes this a no-op for directories already under version
                    // control, while `--depth empty` leaves every child for the
                    // user's later recursive Add.
                    let addParentInvocation = try builder.makeInvocation(
                        for: .add(
                            paths: [parentPath],
                            parents: true,
                            force: true,
                            depth: .empty
                        ),
                        in: coreCopy
                    )
                    let addParentResult = try await runner.run(addParentInvocation)
                    guard addParentResult.succeeded else {
                        throw SVNProcessFailure(result: addParentResult)
                    }

                    // Resolve the directory and selected children again after
                    // the potential add, while the scheduler and cross-process
                    // lock are still held.
                    try Self.validateResolvedBoundary(
                        relativePaths: [parentPath] + targetPaths,
                        in: coreCopy
                    )

                    let listInvocation = try builder.makeInvocation(
                        for: .properties(paths: [parentPath]),
                        in: coreCopy
                    )
                    let listResult = try await runner.run(listInvocation)
                    guard listResult.succeeded else {
                        throw SVNProcessFailure(result: listResult)
                    }

                    let propertyEntries = try SVNXMLParser.parseProperties(
                        listResult.standardOutput
                    )
                    let parentProperties = Self.propertyEntry(
                        for: parentPath,
                        entries: propertyEntries,
                        in: coreCopy
                    )
                // SVN emits an empty <properties> document for a versioned
                // target that has no properties at all. A successful process
                // exit is the authoritative parent-versioned check; however,
                // a nonempty response must still describe the exact target.
                    if !propertyEntries.isEmpty, parentProperties == nil {
                        throw SvnDockServiceError.invalidIgnoreTarget(
                            "无法确认忽略规则父目录的当前属性。"
                        )
                    }
                    let currentValue = parentProperties?.value(forProperty: "svn:ignore")
                    let existingPatterns = currentValue?
                        .components(separatedBy: .newlines)
                        .filter { !$0.isEmpty } ?? []
                    var patterns = existingPatterns
                    var seen = Set(patterns)
                    for rule in rulesForParent {
                        if seen.insert(rule.pattern).inserted {
                            patterns.append(rule.pattern)
                        }
                    }
                // Re-read only the exact targets after the property read and
                // while still holding the working-copy scheduler lease. This
                // closes the long confirmation-window race without scanning a
                // potentially very large working copy (including ignored
                // build directories).
                    let statusInvocation = try builder.makeInvocation(
                        for: .status(SVNStatusOptions(
                            includeIgnored: true,
                            depth: .empty,
                            paths: targetPaths
                        )),
                        in: coreCopy
                    )
                    let statusResult = try await runner.run(statusInvocation)
                    guard statusResult.succeeded else {
                        throw SVNProcessFailure(result: statusResult)
                    }
                    let currentEntries = try SVNXMLParser.parseStatus(
                        statusResult.standardOutput,
                        workingCopyURL: coreCopy.localPath
                    )
                    try Self.validateIgnoreTargets(
                        rulesForParent,
                        entries: currentEntries,
                        in: coreCopy,
                        allowAlreadyIgnored: recommendationPlan != nil
                    )

                // Do not touch the working copy when every requested rule was
                // already present. This also avoids a meaningless property
                // modification after repeated Finder actions.
                    guard patterns != existingPatterns else { continue }

                    try Self.validateResolvedBoundary(
                        relativePaths: [parentPath] + targetPaths,
                        in: coreCopy
                    )

                    let setInvocation = try builder.makeInvocation(
                        for: .setIgnore(path: parentPath, patterns: patterns),
                        in: coreCopy
                    )
                    let setResult = try await runner.run(setInvocation)
                    guard setResult.succeeded else {
                        throw SVNProcessFailure(result: setResult)
                    }
                }
            }
        }
    }

    func ignoredEntries(for workingCopy: SvnDockWorkingCopy) async throws -> [SvnDockStatusEntry] {
        let coreCopy = coreWorkingCopy(for: workingCopy)
        let builder = try SVNCommandBuilder(executableURL: executableLocator.locate())
        let runner = processRunner
        let operationLock = crossProcessLock
        let entries = try await scheduler.enqueue(for: coreCopy.id) {
            try await operationLock.withLock(for: coreCopy.id) {
                // SVN traverses versioned directories; ignored directories stay
                // single rows. Never enumerate their disk descendants here.
                try await Self.ignoredStatus(paths: [], depth: nil, in: coreCopy, builder: builder, runner: runner)
            }
        }
        return try entries.filter { $0.status == .ignored }.map { entry in
            let target = try builder.normalizedLocalPaths([entry.path], in: coreCopy, command: "status")[0]
            let file = coreCopy.localPath.appendingPathComponent(target)
            // lstat-style attributes describe a link itself without visiting
            // its destination, which may lie outside the working copy.
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            let kind = attributes?[.type] as? FileAttributeType
            return SvnDockStatusEntry(
                workingCopyID: coreCopy.id, relativePath: target,
                nodeKind: kind == .typeDirectory ? .directory : .file,
                isSymbolicLink: kind == .typeSymbolicLink, status: .ignored
            )
        }.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    func prepareIgnoreRemoval(for entry: SvnDockStatusEntry, in workingCopy: SvnDockWorkingCopy) async throws -> SvnDockIgnoreRemovalPlan {
        guard entry.workingCopyID == workingCopy.id, entry.status == .ignored else {
            throw SvnDockServiceError.invalidIgnoreTarget("所选项目不属于当前工作副本的已忽略列表，请刷新后重试。")
        }
        let coreCopy = coreWorkingCopy(for: workingCopy)
        let builder = try SVNCommandBuilder(executableURL: executableLocator.locate())
        let runner = processRunner
        let operationLock = crossProcessLock
        return try await scheduler.enqueue(for: coreCopy.id) {
            try await operationLock.withLock(for: coreCopy.id) {
                try await Self.ignoreRemovalPlan(target: entry.relativePath, in: coreCopy, builder: builder, runner: runner)
            }
        }
    }

    func removeIgnoreRule(_ plan: SvnDockIgnoreRemovalPlan, in workingCopy: SvnDockWorkingCopy) async throws {
        let coreCopy = coreWorkingCopy(for: workingCopy)
        guard plan.workingCopyID == coreCopy.id,
              plan.workingCopyRootURL.standardizedFileURL == coreCopy.localPath.standardizedFileURL else {
            throw SvnDockIgnoreRemovalError.stalePlan
        }
        let builder = try SVNCommandBuilder(executableURL: executableLocator.locate())
        let runner = processRunner
        let operationLock = crossProcessLock
        try await scheduler.enqueue(for: coreCopy.id) {
            try await operationLock.withLock(for: coreCopy.id) {
                let current = try await Self.ignoreRemovalPlan(target: plan.targetRelativePath, in: coreCopy, builder: builder, runner: runner)
                guard current.parentRelativePath == plan.parentRelativePath,
                      current.originalPropertyValue == plan.originalPropertyValue,
                      current.patterns == plan.patterns,
                      current.updatedPropertyValue == plan.updatedPropertyValue else {
                    throw SvnDockIgnoreRemovalError.stalePlan
                }
                try Self.validateResolvedBoundary(relativePaths: [current.parentRelativePath, current.targetRelativePath], in: coreCopy)
                // Reuse the validated propset target/argv, supplying the exact
                // remaining property bytes (including blank lines and CRLF).
                // An empty svn:ignore value is valid and affects no other property.
                let template = try builder.makeInvocation(for: .setIgnore(path: current.parentRelativePath, patterns: ["placeholder"]), in: coreCopy)
                let invocation = ProcessInvocation(
                    executableURL: template.executableURL, arguments: template.arguments,
                    currentDirectoryURL: template.currentDirectoryURL, environment: template.environment,
                    standardInput: Data(current.updatedPropertyValue.utf8), argumentFiles: template.argumentFiles
                )
                try Task.checkCancellation()
                let written = try await runner.run(invocation)
                guard written.succeeded else { throw SVNProcessFailure(result: written) }
                let verified: [SvnDockCore.StatusEntry]
                do {
                    try Self.validateResolvedBoundary(relativePaths: [current.parentRelativePath, current.targetRelativePath], in: coreCopy)
                    verified = try await Self.ignoredStatus(paths: [current.targetRelativePath], depth: .empty, in: coreCopy, builder: builder, runner: runner)
                } catch {
                    throw SvnDockIgnoreRemovalError.verificationUnavailable(error.localizedDescription)
                }
                let targetStatus = Self.statusEntry(for: current.targetRelativePath, entries: verified, in: coreCopy)?.status
                if targetStatus == .ignored {
                    throw SvnDockIgnoreRemovalError.stillIgnored
                }
                guard targetStatus == .unversioned else {
                    throw SvnDockIgnoreRemovalError.verificationUnavailable("目标未返回明确的未纳管状态，可能已被移动、删除或由其它客户端修改。")
                }
            }
        }
    }

    private static func ignoredStatus(paths: [String], depth: SVNDepth?, in copy: SvnDockCore.WorkingCopy,
                                      builder: SVNCommandBuilder, runner: any ProcessRunning) async throws -> [SvnDockCore.StatusEntry] {
        let template = try builder.makeInvocation(for: .status(SVNStatusOptions(includeIgnored: true, depth: depth, paths: paths)), in: copy)
        var arguments = template.arguments
        arguments.insert("--ignore-externals", at: 1)
        let result = try await runner.run(ProcessInvocation(executableURL: template.executableURL, arguments: arguments,
            currentDirectoryURL: template.currentDirectoryURL, environment: template.environment,
            standardInput: template.standardInput, argumentFiles: template.argumentFiles))
        guard result.succeeded else { throw SVNProcessFailure(result: result) }
        return try SVNXMLParser.parseStatus(result.standardOutput, workingCopyURL: copy.localPath, resolveNodeKinds: false)
    }

    private static func ignoreRemovalPlan(target requested: String, in copy: SvnDockCore.WorkingCopy,
                                         builder: SVNCommandBuilder, runner: any ProcessRunning) async throws -> SvnDockIgnoreRemovalPlan {
        let target = try builder.normalizedLocalPaths([requested], in: copy, command: "remove ignore")[0]
        guard target != "." else { throw SvnDockIgnoreRemovalError.unsupportedSource }
        let directory = (target as NSString).deletingLastPathComponent
        let parent = directory.isEmpty ? "." : directory
        try validateResolvedBoundary(relativePaths: [parent, target], in: copy)
        _ = try validatedDirectoryURL(for: parent, in: copy)
        let info = try await runner.run(builder.makeInvocation(for: .infoTargets(paths: [parent]), in: copy))
        guard info.succeeded else { throw SvnDockIgnoreRemovalError.unsupportedSource }
        let infos = try SVNXMLParser.parseInfos(info.standardOutput)
        guard let parentInfo = infos.first(where: { absoluteURL(for: $0.path, in: copy) == absoluteURL(for: parent, in: copy) }),
              parentInfo.kind == .directory,
              parentInfo.workingCopyRootURL?.resolvingSymlinksInPath().standardizedFileURL == copy.localPath.resolvingSymlinksInPath().standardizedFileURL else {
            throw SvnDockServiceError.invalidIgnoreTarget("忽略规则父目录不属于当前工作副本，请在所属工作副本单独处理。")
        }
        let properties = try await runner.run(builder.makeInvocation(for: .properties(paths: [parent]), in: copy))
        guard properties.succeeded else { throw SVNProcessFailure(result: properties) }
        let entries = try SVNXMLParser.parseProperties(properties.standardOutput)
        guard let original = propertyEntry(for: parent, entries: entries, in: copy)?.value(forProperty: "svn:ignore") else {
            throw SvnDockIgnoreRemovalError.unsupportedSource
        }
        let removal = SvnDockIgnoreRemovalPlan.removingMatches(from: original, name: (target as NSString).lastPathComponent)
        guard !removal.patterns.isEmpty else { throw SvnDockIgnoreRemovalError.unsupportedSource }
        let siblings = try await ignoredStatus(paths: [parent], depth: .immediates, in: copy, builder: builder, runner: runner)
        guard let selected = statusEntry(for: target, entries: siblings, in: copy), selected.status == .ignored,
              selected.isFileExternal != true else {
            throw SvnDockServiceError.invalidIgnoreTarget("所选项目已不再是可移除直接忽略规则的项目，请刷新后重试。")
        }
        let parentURL = absoluteURL(for: parent, in: copy)
        let affected = try siblings.filter { entry in
            entry.status == .ignored && entry.fileURL(relativeTo: copy).deletingLastPathComponent().standardizedFileURL == parentURL
                && removal.patterns.contains { SvnDockIgnoreRemovalPlan.matches($0, name: (entry.path as NSString).lastPathComponent) }
        }.map { try builder.normalizedLocalPaths([$0.path], in: copy, command: "status")[0] }.sorted()
        return SvnDockIgnoreRemovalPlan(workingCopyID: copy.id, workingCopyRootURL: copy.localPath,
            targetRelativePath: target, parentRelativePath: parent, patterns: removal.patterns,
            originalPropertyValue: original, updatedPropertyValue: removal.value, affectedSiblingPaths: affected)
    }

    func cleanup(workingCopy: SvnDockWorkingCopy) async throws {
        let coreCopy = coreWorkingCopy(for: workingCopy)
        _ = try await run(.cleanup, in: coreCopy)
    }

    private func loadInfo(for workingCopy: SvnDockCore.WorkingCopy) async throws -> SVNInfo {
        let result = try await run(.info, in: workingCopy)
        return try SVNXMLParser.parseInfo(result.standardOutput)
    }

    private func run(
        _ operation: SVNOperationKind,
        in workingCopy: SvnDockCore.WorkingCopy
    ) async throws -> ProcessResult {
        let executableURL = try executableLocator.locate()
        let builder = try SVNCommandBuilder(executableURL: executableURL)
        let invocation = try builder.makeInvocation(for: operation, in: workingCopy)
        let runner = processRunner
        let operationLock = crossProcessLock

        let result = try await scheduler.enqueue(for: workingCopy.id) {
            try await operationLock.withLock(for: workingCopy.id) {
                try await runner.run(invocation)
            }
        }
        guard result.succeeded else {
            throw SVNProcessFailure(result: result)
        }
        return result
    }

    private func coreWorkingCopy(for value: SvnDockWorkingCopy) -> SvnDockCore.WorkingCopy {
        if let existing = coreWorkingCopies[value.id] {
            return existing
        }

        let copy = SvnDockCore.WorkingCopy(
            id: value.id,
            name: value.name,
            localPath: value.rootURL,
            repositoryURL: value.repositoryURL,
            repositoryUUID: value.repositoryUUID,
            revision: value.revision
        )
        coreWorkingCopies[value.id] = copy
        return copy
    }

    private func makeUIWorkingCopy(_ copy: SvnDockCore.WorkingCopy) -> SvnDockWorkingCopy {
        SvnDockWorkingCopy(
            id: copy.id,
            name: copy.name,
            rootURL: copy.localPath,
            repositoryURL: copy.repositoryURL,
            repositoryUUID: copy.repositoryUUID,
            revision: copy.revision
        )
    }

    private func makeUIStatusEntry(
        _ entry: SvnDockCore.StatusEntry,
        in workingCopy: SvnDockCore.WorkingCopy,
        missingInfo: MissingStatusInfo?
    ) -> SvnDockStatusEntry? {
        let effectiveStatus: SvnDockStatusKind
        if entry.isTreeConflicted
            || entry.status == .conflicted
            || entry.propertyStatus == .conflicted {
            effectiveStatus = .conflicted
        } else if entry.status == .normal || entry.status == .none {
            if entry.propertyStatus.isLocalChange {
                effectiveStatus = .modified
            } else if let repositoryStatus = entry.repositoryStatus, repositoryStatus.isLocalChange {
                effectiveStatus = .clean
            } else {
                return nil
            }
        } else {
            effectiveStatus = mapStatus(entry.status)
        }

        if effectiveStatus == .ignored || effectiveStatus == .clean {
            return nil
        }

        let fileURL = entry.fileURL(relativeTo: workingCopy)
        let values = entry.status == .missing ? nil : try? fileURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ])
        let isSymbolicLink = values?.isSymbolicLink == true

        return SvnDockStatusEntry(
            workingCopyID: workingCopy.id,
            relativePath: relativePath(for: fileURL, root: workingCopy.localPath),
            nodeKind: nodeKind(
                missingInfo?.kind ?? entry.kind,
                resourceValues: values,
                isSymbolicLink: isSymbolicLink
            ),
            isSymbolicLink: isSymbolicLink,
            status: effectiveStatus,
            repositoryStatus: entry.repositoryStatus.map(mapStatus),
            conflictKinds: conflictKinds(for: entry),
            changelist: entry.changelist,
            fileSize: values?.fileSize.map { Int64($0) },
            modifiedAt: values?.contentModificationDate,
            workingCopySchedule: missingInfo?.schedule,
            workingCopyRevision: entry.revision
        )
    }

    private func makeUIDirectoryChildren(
        _ listing: DirectoryListingSnapshot,
        in workingCopy: SvnDockCore.WorkingCopy
    ) -> [SvnDockStatusEntry] {
        var statusByPath: [String: SvnDockCore.StatusEntry] = [:]
        for entry in listing.statusEntries {
            let fileURL = entry.fileURL(relativeTo: workingCopy).standardizedFileURL
            guard fileURL.lastPathComponent != ".svn",
                  fileURL.deletingLastPathComponent().standardizedFileURL
                    == listing.directoryURL else {
                continue
            }
            statusByPath[fileURL.path] = entry
        }

        var result: [SvnDockStatusEntry] = []
        result.reserveCapacity(listing.diskChildren.count + statusByPath.count)

        for child in listing.diskChildren {
            let statusEntry = statusByPath.removeValue(forKey: child.fileURL.path)
            result.append(SvnDockStatusEntry(
                workingCopyID: workingCopy.id,
                relativePath: relativePath(
                    for: child.fileURL,
                    root: workingCopy.localPath
                ),
                nodeKind: child.isDirectory && !child.isSymbolicLink
                    ? .directory
                    : .file,
                isSymbolicLink: child.isSymbolicLink,
                status: statusEntry.map(directoryStatusKind) ?? .unversioned,
                repositoryStatus: statusEntry?.repositoryStatus.map(mapStatus),
                conflictKinds: statusEntry.map(conflictKinds(for:)) ?? [],
                changelist: statusEntry?.changelist,
                fileSize: child.fileSize,
                modifiedAt: child.modifiedAt,
                workingCopySchedule: listing.missingInfoByPath[child.fileURL.path]?.schedule,
                workingCopyRevision: statusEntry?.revision
            ))
        }

        // Preserve scheduled deletions and missing nodes even though they no
        // longer have a corresponding item in the directory enumeration.
        for (path, statusEntry) in statusByPath {
            let fileURL = URL(fileURLWithPath: path).standardizedFileURL
            let missingInfo = listing.missingInfoByPath[path]
            result.append(SvnDockStatusEntry(
                workingCopyID: workingCopy.id,
                relativePath: relativePath(
                    for: fileURL,
                    root: workingCopy.localPath
                ),
                nodeKind: nodeKind(missingInfo?.kind ?? statusEntry.kind, resourceValues: nil),
                status: directoryStatusKind(statusEntry),
                repositoryStatus: statusEntry.repositoryStatus.map(mapStatus),
                conflictKinds: conflictKinds(for: statusEntry),
                changelist: statusEntry.changelist,
                workingCopySchedule: missingInfo?.schedule,
                workingCopyRevision: statusEntry.revision
            ))
        }

        return result.sorted { lhs, rhs in
            if lhs.nodeKind != rhs.nodeKind {
                return lhs.nodeKind == .directory
            }
            let nameOrder = lhs.fileName.localizedStandardCompare(rhs.fileName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.relativePath < rhs.relativePath
        }
    }

    private static func missingStatusInfo(
        for entries: [SvnDockCore.StatusEntry],
        in workingCopy: SvnDockCore.WorkingCopy,
        builder: SVNCommandBuilder,
        runner: any ProcessRunning
    ) async throws -> [String: MissingStatusInfo] {
        let paths = entries.compactMap {
            $0.status == .missing || $0.status == .deleted ? $0.path : nil
        }
        guard !paths.isEmpty else { return [:] }

        // `status` reports both missing committed nodes and missing pending
        // additions as "missing". Deleted directories also need their stored
        // kind because they no longer exist on disk. Read this in one local info
        // call; infoTargets uses a targets file when the argument list is large.
        // Keep only the small fields the UI needs, rather than whole SVNInfo
        // records, and do not guess from revisions on copied additions.
        do {
            let invocation = try builder.makeInvocation(for: .infoTargets(paths: paths), in: workingCopy)
            let result = try await runner.run(invocation)
            try Task.checkCancellation()
            guard result.succeeded else { return [:] }
            var metadata: [String: MissingStatusInfo] = [:]
            metadata.reserveCapacity(paths.count)
            for info in try SVNXMLParser.parseInfos(result.standardOutput) {
                let url = info.path.hasPrefix("/")
                    ? URL(fileURLWithPath: info.path)
                    : workingCopy.localPath.appendingPathComponent(info.path)
                metadata[url.standardizedFileURL.path] = MissingStatusInfo(
                    schedule: info.schedule, kind: info.kind
                )
            }
            return metadata
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            // A transient info failure must not hide an otherwise valid status
            // snapshot. Unknown schedules disable the schedule-specific actions.
            return [:]
        }
    }

    private func directoryStatusKind(
        _ entry: SvnDockCore.StatusEntry
    ) -> SvnDockStatusKind {
        if entry.isTreeConflicted
            || entry.status == .conflicted
            || entry.propertyStatus == .conflicted {
            return .conflicted
        }
        if entry.status == .normal || entry.status == .none {
            return entry.propertyStatus.isLocalChange ? .modified : .clean
        }
        return mapStatus(entry.status)
    }

    private func conflictKinds(
        for entry: SvnDockCore.StatusEntry
    ) -> Set<SvnDockConflictKind> {
        var kinds: Set<SvnDockConflictKind> = []
        if entry.status == .conflicted {
            kinds.insert(.text)
        }
        if entry.propertyStatus == .conflicted {
            kinds.insert(.property)
        }
        if entry.isTreeConflicted {
            kinds.insert(.tree)
        }
        return kinds
    }

    private func nodeKind(
        _ kind: SVNNodeKind,
        resourceValues: URLResourceValues?,
        isSymbolicLink: Bool = false
    ) -> SvnDockNodeKind {
        if isSymbolicLink {
            return .file
        }
        switch kind {
        case .file:
            return .file
        case .directory:
            return .directory
        case .unknown:
            return resourceValues?.isDirectory == true ? .directory : .file
        }
    }

    private func mapStatus(_ status: SVNStatus) -> SvnDockStatusKind {
        switch status {
        case .modified, .merged, .incomplete:
            return .modified
        case .added:
            return .added
        case .deleted:
            return .deleted
        case .replaced:
            return .replaced
        case .conflicted:
            return .conflicted
        case .unversioned:
            return .unversioned
        case .missing:
            return .missing
        case .ignored:
            return .ignored
        case .external:
            return .external
        case .obstructed, .unknown:
            return .obstructed
        case .none, .normal:
            return .clean
        }
    }

    private static func validateConflictReplacementFiles(
        _ paths: [String],
        resolution: SvnDockConflictResolution,
        in workingCopy: SvnDockCore.WorkingCopy
    ) throws {
        guard resolution != .working else { return }
        for path in paths {
            // Query a fresh URL each time, including immediately before resolve.
            // File-content replacement is limited to regular files, matching
            // the UI even when an in-root symlink would pass the WC boundary.
            let file = absoluteURL(for: path, in: workingCopy)
            let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values?.isSymbolicLink == false, values?.isRegularFile == true else {
                throw SvnDockServiceError.unavailable(
                    "“\(path)”已变化或不是普通文件，无法替换文件内容。请刷新并核实所选项目。"
                )
            }
        }
    }

    private static func validateConflictTargets(
        _ relativePaths: [String],
        resolution: SvnDockConflictResolution,
        entries: [SvnDockCore.StatusEntry],
        in workingCopy: SvnDockCore.WorkingCopy
    ) throws {
        for relativePath in relativePaths {
            guard let entry = statusEntry(
                for: relativePath,
                entries: entries,
                in: workingCopy
            ), entry.status == .conflicted
                || entry.propertyStatus == .conflicted
                || entry.isTreeConflicted else {
                throw SvnDockServiceError.noConflictedFiles
            }

            guard entry.isFileExternal != true, entry.status != .external else {
                throw SvnDockServiceError.unavailable("“\(relativePath)”属于外部工作副本，请在所属工作副本中单独处理冲突。")
            }

            if resolution != .working {
                guard entry.kind == .file,
                      entry.status == .conflicted,
                      entry.propertyStatus != .conflicted,
                      !entry.isTreeConflicted else {
                    throw SvnDockServiceError.unavailable(
                        "冲突类型已经变化；只有单独的文件内容冲突可以替换内容，请刷新后重试。"
                    )
                }
            }
        }
    }

    private static func validateIgnoreRuleShape(_ rule: SvnDockIgnoreRule) throws {
        guard !rule.targetRelativePath.hasPrefix("/"),
              !rule.parentRelativePath.hasPrefix("/"),
              rule.targetRelativePath != ".",
              !rule.pattern.isEmpty,
              rule.pattern.rangeOfCharacter(
                from: CharacterSet(charactersIn: "\n\r\0")
              ) == nil else {
            throw SvnDockServiceError.invalidIgnoreTarget("忽略规则包含无效路径或字符。")
        }

        let targetPath = rule.targetRelativePath as NSString
        let expectedParent = targetPath.deletingLastPathComponent
        let normalizedParent = expectedParent.isEmpty ? "." : expectedParent
        guard normalizedParent == rule.parentRelativePath else {
            throw SvnDockServiceError.invalidIgnoreTarget("忽略规则与目标父目录不匹配。")
        }

        switch rule.mode {
        case .name:
            guard targetPath.lastPathComponent == rule.pattern else {
                throw SvnDockServiceError.invalidIgnoreTarget("名称忽略规则与目标不匹配。")
            }
        case .fileExtension:
            let fileExtension = targetPath.pathExtension
            guard !fileExtension.isEmpty,
                  rule.pattern == "*.\(fileExtension)" else {
                throw SvnDockServiceError.invalidIgnoreTarget("扩展名忽略规则与目标不匹配。")
            }
        }
    }

    private static func validateIgnoreTargets(
        _ rules: [SvnDockIgnoreRule],
        entries: [SvnDockCore.StatusEntry],
        in workingCopy: SvnDockCore.WorkingCopy,
        allowAlreadyIgnored: Bool = false
    ) throws {
        for rule in rules {
            // A scan below an unversioned ancestor cannot see inherited or
            // client ignore rules. Scheduling the parent at depth empty can
            // expose those rules and turn the selected child into "ignored".
            // It is still unversioned and safe to add the reviewed exact rule.
            guard let entry = statusEntry(
                for: rule.targetRelativePath,
                entries: entries,
                in: workingCopy
            ), entry.status == .unversioned || (allowAlreadyIgnored && entry.status == .ignored) else {
                throw SvnDockServiceError.invalidIgnoreTarget(
                    "“\(rule.targetRelativePath)”的当前状态不允许添加忽略规则，请刷新后重新选择。"
                )
            }
            if rule.mode == .fileExtension, entry.kind != .file {
                throw SvnDockServiceError.invalidIgnoreTarget(
                    "所选项目已经不再是可按扩展名忽略的文件。"
                )
            }
        }
    }

    private static func validatedDirectoryURL(
        for relativePath: String,
        in workingCopy: SvnDockCore.WorkingCopy
    ) throws -> URL {
        try validateResolvedBoundary(
            relativePaths: [relativePath],
            in: workingCopy
        )

        let targetURL = absoluteURL(
            for: relativePath,
            in: workingCopy
        )
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(
                atPath: targetURL.path
            )
        } catch {
            throw SvnDockServiceError.unavailable(
                "无法读取所选目录，请刷新后重试。"
            )
        }

        let fileType = attributes[.type] as? FileAttributeType
        guard fileType != .typeSymbolicLink else {
            throw SvnDockServiceError.unavailable(
                "符号链接目录不能展开，以避免访问工作副本之外的内容。"
            )
        }
        guard fileType == .typeDirectory else {
            throw SvnDockServiceError.unavailable(
                "所选项目已经不再是目录，请刷新后重试。"
            )
        }
        return targetURL
    }

    private static func immediateDiskChildren(
        of directoryURL: URL,
        in workingCopy: SvnDockCore.WorkingCopy
    ) throws -> [DirectoryDiskChild] {
        let fileManager = FileManager.default
        let childURLs = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        let rootURL = workingCopy.localPath.standardizedFileURL

        return childURLs.compactMap { childURL in
            let childURL = childURL.standardizedFileURL
            guard childURL.lastPathComponent != ".svn",
                  childURL.deletingLastPathComponent().standardizedFileURL
                    == directoryURL,
                  path(childURL.path, isInside: rootURL.path) else {
                return nil
            }

            // attributesOfItem reports the link itself, unlike directory
            // traversal APIs that can transparently follow directory links.
            // If metadata races with a deletion, retain a conservative file
            // row rather than attempting to inspect a possible link target.
            let attributes = try? fileManager.attributesOfItem(
                atPath: childURL.path
            )
            let fileType = attributes?[.type] as? FileAttributeType
            return DirectoryDiskChild(
                fileURL: childURL,
                isDirectory: fileType == .typeDirectory,
                isSymbolicLink: fileType == .typeSymbolicLink,
                fileSize: (attributes?[.size] as? NSNumber)?.int64Value,
                modifiedAt: attributes?[.modificationDate] as? Date
            )
        }
    }

    private static func validateResolvedBoundary(
        relativePaths: [String],
        in workingCopy: SvnDockCore.WorkingCopy
    ) throws {
        let root = workingCopy.localPath.standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL

        for relativePath in relativePaths {
            guard !relativePath.isEmpty, !relativePath.contains("\0") else {
                throw SvnDockServiceError.unavailable("目标路径无效，请刷新后重试。")
            }
            let target = relativePath.hasPrefix("/")
                ? URL(fileURLWithPath: relativePath).standardizedFileURL
                : root.appendingPathComponent(relativePath).standardizedFileURL
            guard path(target.path, isInside: root.path) else {
                throw SvnDockServiceError.unavailable("目标路径已经越出工作副本。")
            }

            let resolvedTarget = target.resolvingSymlinksInPath().standardizedFileURL
            guard path(resolvedTarget.path, isInside: resolvedRoot.path) else {
                throw SvnDockServiceError.unavailable(
                    "目标路径已通过符号链接越出工作副本，请刷新后重试。"
                )
            }
        }
    }

    private static func statusEntry(
        for relativePath: String,
        entries: [SvnDockCore.StatusEntry],
        in workingCopy: SvnDockCore.WorkingCopy
    ) -> SvnDockCore.StatusEntry? {
        let expectedURL = absoluteURL(for: relativePath, in: workingCopy)
        return entries.first {
            $0.fileURL(relativeTo: workingCopy).standardizedFileURL == expectedURL
        }
    }

    private static func propertyEntry(
        for relativePath: String,
        entries: [SVNPropertyListEntry],
        in workingCopy: SvnDockCore.WorkingCopy
    ) -> SVNPropertyListEntry? {
        let expectedURL = absoluteURL(for: relativePath, in: workingCopy)
        return entries.first {
            absoluteURL(for: $0.path, in: workingCopy) == expectedURL
        }
    }

    private static func absoluteURL(
        for path: String,
        in workingCopy: SvnDockCore.WorkingCopy
    ) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return workingCopy.localPath
            .appendingPathComponent(path)
            .standardizedFileURL
    }

    private func relativePath(for fileURL: URL, root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        guard fileComponents.starts(with: rootComponents) else {
            return fileURL.lastPathComponent
        }
        let relativePath = fileComponents
            .dropFirst(rootComponents.count)
            .joined(separator: "/")
        return relativePath.isEmpty ? "." : relativePath
    }

    private func removeBadges(
        for removedWorkingCopyID: UUID,
        under root: URL
    ) async throws {
        let rootPath = root.standardizedFileURL.path
        try await sharedStore.removeBadgeEntries(
            forUnregisteredWorkingCopyID: removedWorkingCopyID,
            underWorkingCopyRoot: rootPath
        )
    }

    private func postSharedStateChanged() {
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.svndock.shared-state-changed"),
            object: nil,
            userInfo: nil
        )
    }

    private static func path(_ candidate: String, isInside root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

}

private struct DirectoryDiskChild: Sendable {
    let fileURL: URL
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let fileSize: Int64?
    let modifiedAt: Date?
}

private struct MissingStatusInfo: Sendable {
    let schedule: String?
    let kind: SVNNodeKind
}

private struct StatusListingSnapshot: Sendable {
    let entries: [SvnDockCore.StatusEntry]
    let missingInfoByPath: [String: MissingStatusInfo]
    let finderBadgeWarning: String?
}

private struct DirectoryListingSnapshot: Sendable {
    let directoryURL: URL
    let diskChildren: [DirectoryDiskChild]
    let statusEntries: [SvnDockCore.StatusEntry]
    let missingInfoByPath: [String: MissingStatusInfo]
}

private struct SVNProcessFailure: LocalizedError, Sendable {
    let exitStatus: Int32
    let message: String

    init(result: ProcessResult) {
        exitStatus = result.terminationStatus
        let stderr = result.standardErrorString.trimmingCharacters(in: .whitespacesAndNewlines)
        message = stderr.isEmpty ? "svn 进程以状态码 \(result.terminationStatus) 退出。" : stderr
    }

    var errorDescription: String? {
        if message.contains("E155010"),
           message.contains("is scheduled for addition, but is missing") {
            return "待添加的文件在本地已不存在。若仍需提交，请恢复文件后刷新；若不再需要，请取消该路径的添加计划。\n\n\(message)"
        }
        return message
    }
}
