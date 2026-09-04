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
        let info = try await loadInfo(for: workingCopy)

        if let rootURL = info.workingCopyRootURL {
            workingCopy = SvnDockCore.WorkingCopy(
                id: workingCopy.id,
                localPath: rootURL,
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

        coreWorkingCopies[workingCopy.id] = workingCopy
        _ = try await sharedStore.register(workingCopy)
        postSharedStateChanged()
        return makeUIWorkingCopy(workingCopy)
    }

    func unregisterWorkingCopy(id: UUID) async throws {
        let removedCopy = coreWorkingCopies.removeValue(forKey: id)
        _ = try await sharedStore.unregister(id: id)

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
            for: .status(SVNStatusOptions(showRemoteUpdates: false, includeIgnored: false)),
            in: coreCopy
        )
        let runner = processRunner
        let operationLock = crossProcessLock
        let badgeStore = sharedStore

        // Keep the WC lease through status parsing and badge persistence. If
        // the lock were released immediately after `svn status`, an Agent
        // mutation could publish newer badges and then be overwritten by this
        // stale result.
        let coreEntries = try await scheduler.enqueue(for: coreCopy.id) {
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
                let replacement = Self.badgeReplacement(entries, in: coreCopy)
                try await badgeStore.replaceBadgeEntries(
                    forWorkingCopyID: coreCopy.id,
                    underWorkingCopyRoot: coreCopy.localPath.standardizedFileURL.path,
                    with: replacement
                )
                return entries
            }
        }

        let uiEntries = coreEntries.compactMap { entry in
            makeUIStatusEntry(entry, in: coreCopy)
        }
        postSharedStateChanged()
        return SvnDockStatusSnapshot(entries: uiEntries)
    }

    func diff(
        relativePath: String,
        in workingCopy: SvnDockWorkingCopy
    ) async throws -> String {
        let coreCopy = coreWorkingCopy(for: workingCopy)
        let result = try await run(.diff(paths: [relativePath]), in: coreCopy)
        return result.standardOutputString
    }

    func history(
        for workingCopy: SvnDockWorkingCopy,
        relativePaths: [String],
        limit: Int
    ) async throws -> [SvnDockLogEntry] {
        let coreCopy = coreWorkingCopy(for: workingCopy)
        let result = try await run(.log(paths: relativePaths, limit: limit), in: coreCopy)
        return try SVNXMLParser.parseLog(result.standardOutput).map {
            SvnDockLogEntry(
                revision: $0.revision,
                author: $0.author,
                date: $0.date,
                message: $0.message
            )
        }
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
        let coreCopy = coreWorkingCopy(for: workingCopy)
        _ = try await run(
            .commit(paths: relativePaths, message: message, keepLocks: false),
            in: coreCopy
        )
    }

    func add(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws {
        let coreCopy = coreWorkingCopy(for: workingCopy)
        _ = try await run(.add(paths: relativePaths, parents: true), in: coreCopy)
    }

    func revert(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws {
        let coreCopy = coreWorkingCopy(for: workingCopy)
        // Revert only the exact status rows the user confirmed. A directory
        // row can represent a property-only change (for example svn:ignore);
        // recursively reverting it would also discard unrelated child edits.
        _ = try await run(.revert(paths: relativePaths, depth: .empty), in: coreCopy)
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
        let statusInvocation = try builder.makeInvocation(
            for: .status(SVNStatusOptions(paths: relativePaths)),
            in: coreCopy
        )
        let resolveInvocation = try builder.makeInvocation(
            for: .resolve(paths: relativePaths, accept: choice),
            in: coreCopy
        )
        let runner = processRunner
        let operationLock = crossProcessLock

        try await scheduler.enqueue(for: coreCopy.id) {
            try await operationLock.withLock(for: coreCopy.id) {
                try Self.validateResolvedBoundary(
                    relativePaths: relativePaths,
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
                    relativePaths,
                    resolution: resolution,
                    entries: currentEntries,
                    in: coreCopy
                )

                // Resolve symlinks again immediately before the mutation. The
                // confirmation dialog may have remained open for an arbitrary
                // amount of time after Finder originally queued the request.
                try Self.validateResolvedBoundary(
                    relativePaths: relativePaths,
                    in: coreCopy
                )
                let resolveResult = try await runner.run(resolveInvocation)
                guard resolveResult.succeeded else {
                    throw SVNProcessFailure(result: resolveResult)
                }
            }
        }
    }

    func addIgnoreRules(
        _ rules: [SvnDockIgnoreRule],
        in workingCopy: SvnDockWorkingCopy
    ) async throws {
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
                for parentPath in groupedRules.keys.sorted() {
                    try Task.checkCancellation()
                    guard let rulesForParent = groupedRules[parentPath] else { continue }

                    let targetPaths = rulesForParent.map(\.targetRelativePath)
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
                        in: coreCopy
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
            revision: copy.revision
        )
    }

    private func makeUIStatusEntry(
        _ entry: SvnDockCore.StatusEntry,
        in workingCopy: SvnDockCore.WorkingCopy
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
        let values = try? fileURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey
        ])

        return SvnDockStatusEntry(
            workingCopyID: workingCopy.id,
            relativePath: relativePath(for: fileURL, root: workingCopy.localPath),
            nodeKind: nodeKind(entry.kind, resourceValues: values),
            status: effectiveStatus,
            repositoryStatus: entry.repositoryStatus.map(mapStatus),
            conflictKinds: conflictKinds(for: entry),
            changelist: entry.changelist,
            fileSize: values?.fileSize.map { Int64($0) },
            modifiedAt: values?.contentModificationDate
        )
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
        resourceValues: URLResourceValues?
    ) -> SvnDockNodeKind {
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

            if resolution != .working {
                guard entry.kind == .file,
                      entry.status == .conflicted,
                      entry.propertyStatus != .conflicted,
                      !entry.isTreeConflicted else {
                    throw SvnDockServiceError.unavailable(
                        "冲突类型已经变化；只有纯文本文件冲突可以替换内容，请刷新后重试。"
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
        in workingCopy: SvnDockCore.WorkingCopy
    ) throws {
        for rule in rules {
            guard let entry = statusEntry(
                for: rule.targetRelativePath,
                entries: entries,
                in: workingCopy
            ), entry.status == .unversioned else {
                throw SvnDockServiceError.invalidIgnoreTarget(
                    "所选项目已经不再是未纳管状态，请刷新后重试。"
                )
            }
            if rule.mode == .fileExtension, entry.kind != .file {
                throw SvnDockServiceError.invalidIgnoreTarget(
                    "所选项目已经不再是可按扩展名忽略的文件。"
                )
            }
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

    private static func badgeReplacement(
        _ entries: [SvnDockCore.StatusEntry],
        in workingCopy: SvnDockCore.WorkingCopy
    ) -> [String: BadgeKind] {
        let rootPath = workingCopy.localPath.standardizedFileURL.path
        var replacement: [String: BadgeKind] = [:]

        var rootBadge: BadgeKind?
        for entry in entries where entry.hasLocalChanges {
            let path = entry.fileURL(relativeTo: workingCopy).standardizedFileURL.path
            let badge = BadgeKind(statusEntry: entry)
            replacement[path] = badge
            rootBadge = Self.higherPriority(rootBadge, badge)
        }
        if let rootBadge {
            replacement[rootPath] = rootBadge
        }
        return replacement
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
}

private struct SVNProcessFailure: LocalizedError, Sendable {
    let exitStatus: Int32
    let message: String

    init(result: ProcessResult) {
        exitStatus = result.terminationStatus
        let stderr = result.standardErrorString.trimmingCharacters(in: .whitespacesAndNewlines)
        message = stderr.isEmpty ? "svn 进程以状态码 \(result.terminationStatus) 退出。" : stderr
    }

    var errorDescription: String? { message }
}
