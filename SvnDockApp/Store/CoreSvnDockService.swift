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
                let replacement = Self.badgeReplacement(entries, in: coreCopy)
                try await badgeStore.replaceBadgeEntries(
                    forWorkingCopyID: coreCopy.id,
                    underWorkingCopyRoot: coreCopy.localPath.standardizedFileURL.path,
                    with: replacement
                )
                return StatusListingSnapshot(entries: entries, missingInfoByPath: missingInfoByPath)
            }
        }

        let uiEntries = listing.entries.compactMap { entry in
            makeUIStatusEntry(
                entry, in: coreCopy,
                missingInfo: entry.status == .missing || entry.status == .deleted
                    ? listing.missingInfoByPath[entry.fileURL(relativeTo: coreCopy).path]
                    : nil
            )
        }
        postSharedStateChanged()
        return SvnDockStatusSnapshot(entries: uiEntries)
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
        return try SVNRevisionDetails.combining(
            repositoryRootURL: root, entry: entry,
            summary: SVNXMLParser.parseDiffSummary(summary.standardOutput)
        )
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
        let coreCopy = coreWorkingCopy(for: workingCopy)
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
                for (paths, depth) in groups where !paths.isEmpty {
                    try Task.checkCancellation()
                    try Self.validateResolvedBoundary(relativePaths: paths, in: coreCopy)
                    let result = try await runner.run(builder.makeInvocation(
                        for: .revert(paths: paths, depth: depth), in: coreCopy
                    ))
                    guard result.succeeded else { throw SVNProcessFailure(result: result) }
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
