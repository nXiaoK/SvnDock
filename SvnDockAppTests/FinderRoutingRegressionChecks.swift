import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum FinderRoutingRegressionChecks {
    @MainActor
    static func run() async throws {
        try await cleanTargetsRemainExplicit()
        try await unavailableHistoryPathsRequireExplicitSelection()
        try await finderCommitOverridesOnlyTheInitialScope()
        try await directorySelectionRespectsPathBoundaries()
        try await openingDirectoriesLocatesTheExactNode()
        try await confirmationBlocksLaterRequestsAndCancellationIsDurable()
        try await invalidRequestsCannotReachTargetOperations()
        try await backgroundBadgesPreserveInteractionAndRespectGates()
        print("Finder routing checks passed: clean targets, file history focus, explicit commit scope, cancellation, duplicates and boundaries")
    }

    @MainActor
    private static func unavailableHistoryPathsRequireExplicitSelection() async throws {
        let oldPath = "/trunk/旧名称@文本.swift"
        let unrelated = SVNChangedPath(path: "/trunk/other.swift", action: .modified, kind: .file)
        let renamed = SVNChangedPath(path: "/trunk/new.swift", action: .added, kind: .file,
                                    copyFromPath: oldPath, copyFromRevision: 8, isMove: true)
        let secondCopy = SVNChangedPath(path: "/trunk/another-copy.swift", action: .added, kind: .file,
                                       copyFromPath: oldPath, copyFromRevision: 8)
        let request = SvnDockRevisionRequest(workingCopyID: UUID(), revision: 9, preferredPath: oldPath)
        for changes in [[unrelated], [unrelated, renamed, secondCopy]] {
            let model = HistoryRevisionModel(detailsLoader: { requested in
                SVNRevisionDetails(repositoryRootURL: URL(string: "https://example.test/repo")!,
                    entry: SVNLogEntry(revision: requested.revision, author: nil, date: nil, message: "fixture"), changes: changes)
            }, diffLoader: { _, change, _ in change.path })
            await model.load(request)
            try check(model.selectedPath == nil && model.diffText.isEmpty && model.preferredPathNotice != nil,
                      "missing or ambiguous historical paths never default to an unrelated file")
            model.select(unrelated.path)
            try await waitUntil { !model.isLoadingDiff }
            try check(model.diffText == unrelated.path && model.preferredPathNotice == nil,
                      "the user can explicitly choose another changed file after an unresolved history focus")
            model.cancel()
        }
        let model = HistoryRevisionModel(detailsLoader: { requested in
            SVNRevisionDetails(repositoryRootURL: URL(string: "https://example.test/repo")!,
                entry: SVNLogEntry(revision: requested.revision, author: nil, date: nil, message: "fixture"),
                changes: [unrelated, renamed])
        }, diffLoader: { _, change, _ in change.path })
        await model.load(request)
        try await waitUntil { !model.isLoadingDiff }
        try check(model.selectedPath == renamed.path, "a unique recorded copy source locates the moved file")
        model.pathQuery = "other.swift"
        try await waitUntil { !model.isFiltering }
        try check(model.selectedPath == nil && model.preferredPathNotice?.contains("筛选隐藏") == true,
                  "filtering away the explicit history focus does not silently select another file")
        model.cancel()
    }

    @MainActor
    private static func cleanTargetsRemainExplicit() async throws {
        let fixture = try await FinderRoutingFixture.make()
        defer { fixture.remove() }
        let store = fixture.store
        let originalCounts = store.statusCounts
        store.statusFilter = .conflicts
        store.searchQuery = "a filter that hides the Finder target"
        let diff = try await fixture.enqueue(.diff, paths: [FinderRoutingFixture.cleanPath])
        await store.handleFinderURL(fixture.url(for: diff))
        try check(store.presentedError == nil && store.diffLoadError == nil
                    && store.inspectorTab == .diff && store.diffText.isEmpty,
                  "a clean versioned file opens a successful empty diff")
        try check(store.finderSelectedTarget?.entry.relativePath == FinderRoutingFixture.cleanPath
                    && store.finderSelectedTarget?.entry.status == .clean,
                  "an explicit clean Finder target remains available to the inspector")
        try check(store.statusFilter == .all && store.searchQuery.isEmpty,
                  "Finder navigation clears filters that would hide the requested target")
        try check(store.statusCounts == originalCounts
                    && !store.entries.contains { $0.relativePath == FinderRoutingFixture.cleanPath }
                    && !store.committableEntries.contains { $0.relativePath == FinderRoutingFixture.cleanPath },
                  "the clean focus does not become a local change or a committable item")
        try check(await fixture.service.diffPaths == [FinderRoutingFixture.cleanPath],
                  "diff receives the exact literal Unicode and at-sign path")
        try check(try await fixture.coordinator.location(of: diff.id) == .completed(.completed),
                  "empty text diff is acknowledged as completed rather than quarantined")
        await store.handleFinderURL(fixture.url(for: diff))
        try check(await fixture.service.diffPaths.count == 1, "a repeated completed URL cannot reload or replay its operation")

        let log = try await fixture.enqueue(.log, paths: [FinderRoutingFixture.cleanPath])
        await store.handleFinderURL(fixture.url(for: log))
        guard let target = store.historyTarget else { throw FinderRoutingFailure(message: "missing explicit file history target") }
        try check(target.relativePaths == [FinderRoutingFixture.cleanPath]
                    && target.source == .finderExplicit
                    && target.preferredRepositoryPath == FinderRoutingFixture.repositoryPath,
                  "Finder history retains both the local path and its authoritative repository path")
        try check(store.selectedEntryIDs.isEmpty && store.inspectorTab == .history,
                  "explicit file history does not depend on a changed status row")
        await store.ensureHistoryForSelection()
        try check(store.historyTarget == target, "the inspector selection task cannot replace explicit file history with root history")
        try check(await fixture.service.historyPaths == [[FinderRoutingFixture.cleanPath]],
                  "history queries only the requested file once, with literal path characters preserved")
        let request = target.revisionRequest(for: 9)
        try check(request.preferredPath == FinderRoutingFixture.repositoryPath,
                  "history list and window requests carry the target's repository-relative selection")
        let model = HistoryRevisionModel(store: store)
        await model.load(request)
        try await waitUntil { !model.isLoadingDiff }
        try check(model.selectedPath == FinderRoutingFixture.repositoryPath
                    && model.diffText == FinderRoutingFixture.repositoryPath,
                  "a multi-file revision opens the requested file rather than its first changed path")
        try check(model.displayedChanges.contains { $0.path == FinderRoutingFixture.repositoryPath },
                  "a preferred path beyond the initial 300 rows is made visible")
        model.cancel()
        let rootTarget = SvnDockHistoryTarget(workingCopy: fixture.copy, relativePaths: [],
            title: fixture.copy.name, source: .workingCopy)
        try check(rootTarget.revisionRequest(for: 9).preferredPath == nil,
                  "ordinary root history keeps its existing default path selection")
        try check(try await fixture.coordinator.location(of: log.id) == .completed(.completed),
                  "explicit file history leaves a completed queue receipt")
        await fixture.service.moveRepository(to: "/branches/new-place")
        let movedLog = try await fixture.enqueue(.log, paths: [FinderRoutingFixture.cleanPath])
        await store.handleFinderURL(fixture.url(for: movedLog))
        try check(store.historyTarget?.id != target.id
                    && store.historyTarget?.preferredRepositoryPath == "/branches/new-place/" + FinderRoutingFixture.cleanPath,
                  "the same local file at another repository path gets a new history identity")
        try check(await fixture.service.historyPaths.count == 2,
                  "updated repository coordinates cannot reuse the old file history cache")
    }

    @MainActor
    private static func finderCommitOverridesOnlyTheInitialScope() async throws {
        let fixture = try await FinderRoutingFixture.make()
        defer { fixture.remove() }
        let store = fixture.store
        let saved = SvnDockCommitDraft(message: "Keep the existing description", includedRelativePaths: ["C.swift"],
                                       previewRelativePath: "C.swift")
        try store.commitDraftStore.save(saved, for: fixture.copy)
        let command = try await fixture.enqueue(.commit, paths: ["A.swift", "B.swift"])
        await store.handleFinderURL(fixture.url(for: command))
        try check(store.isPresentingCommit, "Finder commit opens an awaiting-user submission sheet")
        let initial = SvnDockCommitDraft.initialIncludedEntryIDs(entries: store.committableEntries,
            selectedEntryIDs: store.selectedEntryIDs, savedDraft: saved,
            explicitEntryIDs: store.commitInitialSelectedEntryIDs)
        let includedPaths = Set(store.committableEntries.filter { initial.contains($0.id) }.map(\.relativePath))
        try check(includedPaths == Set(["A.swift", "B.swift"]),
                  "Finder's selected A/B scope overrides a saved C selection")
        try check(try store.commitDraftStore.draft(for: fixture.copy) == saved,
                  "opening a Finder commit preserves the existing draft description and stored draft")
        try check(await fixture.service.commitPaths.isEmpty, "opening the sheet does not execute a commit")
        store.commit(message: saved.message, entryIDs: initial)
        store.commit(message: saved.message, entryIDs: initial)
        try await waitUntil { !store.isBusy && !store.isPresentingCommit }
        let commits = await fixture.service.commitPaths
        try check(commits.count == 1 && Set(commits[0]) == Set(["A.swift", "B.swift"]),
                  "the exact initial scope reaches one commit without unrelated draft paths")
        try check(try await fixture.coordinator.location(of: command.id) == .completed(.completed),
                  "the confirmed commit writes one completed receipt")
        await store.handleFinderURL(fixture.url(for: command))
        try check(await fixture.service.commitPaths.count == 1, "repeated commit URLs cannot reopen or execute a completed request")

        // The Finder override must not change normal App draft restoration.
        try store.commitDraftStore.save(saved, for: fixture.copy)
        store.requestCommit()
        try check(store.commitInitialSelectedEntryIDs == nil, "ordinary App submission has no lingering Finder override")
        let normal = SvnDockCommitDraft.initialIncludedEntryIDs(entries: store.committableEntries,
            selectedEntryIDs: store.selectedEntryIDs, savedDraft: saved,
            explicitEntryIDs: store.commitInitialSelectedEntryIDs)
        try check(Set(store.committableEntries.filter { normal.contains($0.id) }.map(\.relativePath)) == ["C.swift"],
                  "ordinary App submission still restores its saved selection")
        store.cancelCommit()
    }

    @MainActor
    private static func directorySelectionRespectsPathBoundaries() async throws {
        let fixture = try await FinderRoutingFixture.make()
        defer { fixture.remove() }
        let command = try await fixture.enqueue(.commit, paths: ["D"])
        await fixture.store.handleFinderURL(fixture.url(for: command))
        let ids = fixture.store.commitInitialSelectedEntryIDs ?? []
        let paths = Set(fixture.store.committableEntries.filter { ids.contains($0.id) }.map(\.relativePath))
        try check(paths == ["D", "D/one.swift", "D/sub/two.swift"],
                  "selecting a directory includes its modified descendants but excludes the D2 prefix sibling")
        fixture.store.cancelCommit()
        try await waitUntil { !fixture.store.isBusy }
        try check(try await fixture.coordinator.location(of: command.id) == .completed(.cancelled),
                  "closing the directory submission acknowledges cancellation")
    }

    @MainActor
    private static func openingDirectoriesLocatesTheExactNode() async throws {
        let fixture = try await FinderRoutingFixture.make()
        defer { fixture.remove() }
        for path in ["D", "D/sub", "loose.txt"] {
            fixture.store.inspectorTab = .diff
            let command = try await fixture.enqueue(.openApp, paths: [path])
            await fixture.store.handleFinderURL(fixture.url(for: command))
            try check(fixture.store.presentedError == nil
                        && fixture.store.selectedEntryIDs.count == 1
                        && fixture.store.primarySelectedEntry?.relativePath == path
                        && fixture.store.inspectorTab == .information,
                      "opening a Finder item locates that node, not its modified descendants")
            try check(try await fixture.coordinator.location(of: command.id) == .completed(.completed),
                      "opening an exact directory or unversioned item completes its queue request")
            if path == "D/sub" {
                try check(fixture.store.finderTargetOutsideChangeList?.nodeKind == .directory
                            && fixture.store.finderTargetOutsideChangeList?.status == .clean,
                          "a clean directory with modified children remains a precise navigation target")
            }
        }
        try check(await fixture.service.targetPaths == ["D/sub"],
                  "known modified and unversioned nodes do not require a versioned-only target lookup")
    }

    @MainActor
    private static func confirmationBlocksLaterRequestsAndCancellationIsDurable() async throws {
        let fixture = try await FinderRoutingFixture.make()
        defer { fixture.remove() }
        let first = try await fixture.enqueue(.commit, paths: ["A.swift"])
        await fixture.store.handleFinderURL(fixture.url(for: first))
        let originalSelection = fixture.store.selectedEntryIDs
        let second = try await fixture.enqueue(.log, paths: [FinderRoutingFixture.cleanPath])
        let subsequentRequest = Task { await fixture.store.handleFinderURL(fixture.url(for: second)) }
        try await Task.sleep(for: .milliseconds(100))
        try check(fixture.store.isPresentingCommit && fixture.store.selectedEntryIDs == originalSelection,
                  "a later Finder request cannot replace an open commit's confirmation context")
        try check(await fixture.service.historyPaths.isEmpty,
                  "a request behind a confirmation cannot begin its target operation")
        fixture.store.cancelCommit()
        await subsequentRequest.value
        try await waitUntil { !fixture.store.isBusy }
        try check(try await fixture.coordinator.location(of: first.id) == .completed(.cancelled),
                  "cancel is durable before the next request finishes")
        try check(try await fixture.coordinator.location(of: second.id) == .completed(.completed),
                  "the queued file history proceeds after cancellation")
        await fixture.store.handleFinderURL(fixture.url(for: first))
        try check(!fixture.store.isPresentingCommit && fixture.store.commitInitialSelectedEntryIDs == nil,
                  "reopening a cancelled URL cannot revive its selection override")
        try check(await fixture.service.commitPaths.isEmpty, "cancellation and repeated URLs never execute a commit")
    }

    @MainActor
    private static func invalidRequestsCannotReachTargetOperations() async throws {
        let fixture = try await FinderRoutingFixture.make()
        defer { fixture.remove() }
        let root = fixture.copy.rootURL
        let outside = fixture.temporary.appendingPathComponent("outside.swift")
        try Data("outside\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escaped.swift"), withDestinationURL: outside)
        let valid = root.appendingPathComponent("A.swift").path
        let commands = [
            FinderCommand(kind: .diff, paths: [outside.path], workingCopyRoot: root.path),
            FinderCommand(kind: .diff, paths: [root.appendingPathComponent("escaped.swift").path], workingCopyRoot: root.path),
            FinderCommand(kind: .diff, paths: [valid, valid], workingCopyRoot: root.path),
            FinderCommand(kind: .diff, paths: [valid], workingCopyRoot: root.path,
                          createdAt: Date().addingTimeInterval(-301)),
            FinderCommand(kind: .diff, paths: [valid], workingCopyRoot: root.path,
                          createdAt: Date().addingTimeInterval(120)),
            FinderCommand(kind: .diff, paths: [valid], workingCopyRoot: root.path, source: "untrusted-source")
        ]
        for command in commands {
            _ = try await fixture.shared.enqueue(command)
            await fixture.store.handleFinderURL(fixture.url(for: command))
            try check(fixture.store.presentedError != nil, "invalid Finder intent produces visible feedback")
            try check(try await fixture.coordinator.location(of: command.id) == .completed(.rejected),
                      "invalid scope, source or timestamp is rejected before execution")
            fixture.store.presentedError = nil
        }
        try check(await fixture.service.targetPaths.isEmpty, "invalid boundary requests cannot reach target inspection")
        for (kind, paths) in [(FinderCommandKind.diff, ["A.swift", "B.swift"]),
                              (.log, ["A.swift", "B.swift"]), (.diff, ["loose.txt"]), (.log, ["loose.txt"])] {
            let command = try await fixture.enqueue(kind, paths: paths)
            await fixture.store.handleFinderURL(fixture.url(for: command))
            try check(fixture.store.presentedError != nil, "invalid single-target and unversioned requests do not silently succeed")
            let location = try await fixture.coordinator.location(of: command.id)
            try check(location != .completed(.completed), "a failed read is never acknowledged as successfully displayed")
            fixture.store.presentedError = nil
        }
        let unregistered = fixture.temporary.appendingPathComponent("unregistered", isDirectory: true)
        try FileManager.default.createDirectory(at: unregistered, withIntermediateDirectories: false)
        let unknown = FinderCommand(kind: .diff, paths: [unregistered.appendingPathComponent("file.swift").path],
                                    workingCopyRoot: unregistered.path)
        _ = try await fixture.shared.enqueue(unknown)
        await fixture.store.handleFinderURL(fixture.url(for: unknown))
        try check(fixture.store.presentedError != nil, "unregistered roots fail with visible feedback")
        let diffPaths = await fixture.service.diffPaths
        let historyPaths = await fixture.service.historyPaths
        let commitPaths = await fixture.service.commitPaths
        try check(diffPaths.isEmpty && historyPaths.isEmpty && commitPaths.isEmpty,
                  "all rejected requests leave target operations unexecuted")
    }

    @MainActor
    private static func backgroundBadgesPreserveInteractionAndRespectGates() async throws {
        let fixture = try await FinderRoutingFixture.make()
        defer { fixture.remove() }
        let store = fixture.store
        let now = Date()
        await store.refreshFinderBadgesIfNeeded(now: now)
        try check(await fixture.service.badgeRefreshes.isEmpty, "no Finder observation means no background SVN refresh")
        try fixture.writeBadgeObservation(updatedAt: now)
        guard let selected = store.entries.first(where: { $0.relativePath == "A.swift" }) else {
            throw FinderRoutingFailure(message: "missing background selection")
        }
        store.selectedEntryIDs = [selected.id]
        store.searchQuery = "A.swift"
        let beforeEntries = store.entries
        let beforeCounts = store.statusCounts
        let beforeStatusCalls = await fixture.service.statusCalls
        let draft = SvnDockCommitDraft(message: "Background refresh must preserve this", includedRelativePaths: ["C.swift"],
                                      previewRelativePath: "C.swift")
        try store.commitDraftStore.save(draft, for: fixture.copy)
        await store.refreshFinderBadgesIfNeeded(now: now)
        let calls = await fixture.service.badgeRefreshes
        try check(calls.count == 1
                    && Set(calls[0].directories) == Set([fixture.copy.rootURL.path,
                        fixture.copy.rootURL.appendingPathComponent("src").path])
                    && calls[0].preferred == [fixture.copy.rootURL.appendingPathComponent(FinderRoutingFixture.cleanPath).path],
                  "background refresh uses the observed directories and requested visible item paths")
        let afterStatusCalls = await fixture.service.statusCalls
        try check(store.selectedEntryIDs == [selected.id] && store.searchQuery == "A.swift"
                    && store.entries == beforeEntries && store.statusCounts == beforeCounts
                    && beforeStatusCalls == afterStatusCalls && store.operationRecords.isEmpty,
                  "background badges do not reload the main list or change selection, counts or operation history")
        try check(try store.commitDraftStore.draft(for: fixture.copy) == draft,
                  "background badges leave commit drafts intact")
        await store.refreshFinderBadgesIfNeeded(now: now.addingTimeInterval(5))
        try check(await fixture.service.badgeRefreshes.count == 1, "one working copy refreshes at most once inside ten seconds")
        await store.refreshFinderBadgesIfNeeded(now: now.addingTimeInterval(11))
        try check(await fixture.service.badgeRefreshes.count == 2, "an active observation refreshes again after the throttle interval")

        store.requestCommit()
        await store.refreshFinderBadgesIfNeeded(now: now.addingTimeInterval(22))
        try check(await fixture.service.badgeRefreshes.count == 2, "an open submission sheet defers background refresh")
        store.cancelCommit()
        await fixture.service.holdNextUpdate()
        let update = Task { await store.update(workingCopyIDs: [fixture.copy.id]) }
        try await waitUntil { await fixture.service.hasPendingUpdate }
        await store.refreshFinderBadgesIfNeeded(now: now.addingTimeInterval(22))
        try check(await fixture.service.badgeRefreshes.count == 2, "an active working-copy operation defers background refresh")
        await fixture.service.finishPendingUpdate()
        _ = await update.value
        await fixture.service.failNextBadgeRefresh()
        await store.refreshFinderBadgesIfNeeded(now: now.addingTimeInterval(22))
        try check(store.finderBadgeRefreshError != nil && store.presentedError == nil,
                  "a background error stays in badge status without opening an interrupting alert")
        let commits = await fixture.service.commitPaths
        try check(commits.isEmpty, "background refresh never executes a commit")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw FinderRoutingFailure(message: message) }
    }

    @MainActor
    private static func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard clock.now < deadline else { throw FinderRoutingFailure(message: "Finder routing operation timed out") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private struct FinderRoutingFailure: Error { let message: String }

@MainActor
private struct FinderRoutingFixture {
    static let cleanPath = "src/clean@文本.swift"
    static let repositoryPath = "/branches/feature/src/clean@文本.swift"
    let temporary: URL
    let copy: SvnDockWorkingCopy
    let shared: FinderSharedStore
    let coordinator: FinderCommandQueueCoordinator
    let service: FinderRoutingService
    let store: SvnDockStore
    let defaults: UserDefaults
    let suite: String

    static func make() async throws -> FinderRoutingFixture {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("svndock-finder-routing-\(UUID())", isDirectory: true)
        let root = temporary.appendingPathComponent("wc", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for path in [cleanPath, "A.swift", "B.swift", "C.swift", "D/one.swift", "D/sub/two.swift", "D2/other.swift", "loose.txt"] {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture contents\n".utf8).write(to: file)
        }
        let copy = SvnDockWorkingCopy(name: "Finder fixture", rootURL: root,
                                     repositoryURL: URL(string: "https://example.test/repo/branches/feature"), revision: 9)
        let shared = try FinderSharedStore(directoryURL: temporary.appendingPathComponent("shared"))
        _ = try await shared.register(WorkingCopy(id: copy.id, name: copy.name, localPath: root))
        let coordinator = try FinderCommandQueueCoordinator(directoryURL: shared.directoryURL)
        let service = FinderRoutingService(copy: copy)
        let suite = "svndock-finder-routing-\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { throw FinderRoutingFailure(message: "cannot create isolated drafts") }
        let store = SvnDockStore(service: service, finderSharedStore: shared,
                                 commitDraftStore: SvnDockCommitDraftStore(defaults: defaults))
        guard await store.load() else { throw FinderRoutingFailure(message: "cannot load Finder fixture") }
        return FinderRoutingFixture(temporary: temporary, copy: copy, shared: shared, coordinator: coordinator,
                                     service: service, store: store, defaults: defaults, suite: suite)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: temporary)
    }

    func enqueue(_ kind: FinderCommandKind, paths: [String]) async throws -> FinderCommand {
        let command = FinderCommand(kind: kind, paths: paths.map { copy.rootURL.appendingPathComponent($0).path },
                                     workingCopyRoot: copy.rootURL.path)
        _ = try await shared.enqueue(command)
        return command
    }

    func url(for command: FinderCommand) -> URL {
        URL(string: "svndock://finder-command?request=\(command.id.uuidString)")!
    }

    func writeBadgeObservation(updatedAt: Date) throws {
        let directory = shared.directoryURL.appendingPathComponent(FinderBadgeRefreshRequestStore.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let request = FinderBadgeRefreshRequest(id: UUID(), updatedAt: updatedAt, directories: [
            FinderBadgeRefreshDirectory(workingCopyID: copy.id, workingCopyRoot: copy.rootURL.path,
                directoryPath: copy.rootURL.path),
            FinderBadgeRefreshDirectory(workingCopyID: copy.id, workingCopyRoot: copy.rootURL.path,
                directoryPath: copy.rootURL.appendingPathComponent("src").path,
                itemPaths: [copy.rootURL.appendingPathComponent(Self.cleanPath).path])
        ])
        let file = directory.appendingPathComponent(request.id.uuidString.lowercased() + ".json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(request).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

private actor FinderRoutingService: SvnDockServicing {
    struct BadgeRefresh: Sendable {
        let directories: [String]
        let preferred: [String]
    }
    let copy: SvnDockWorkingCopy
    private(set) var targetPaths: [String] = []
    private(set) var diffPaths: [String] = []
    private(set) var historyPaths: [[String]] = []
    private(set) var commitPaths: [[String]] = []
    private(set) var badgeRefreshes: [BadgeRefresh] = []
    private(set) var statusCalls = 0
    private var shouldHoldUpdate = false
    private var shouldFailBadgeRefresh = false
    private var pendingUpdate: CheckedContinuation<Void, Never>?
    private var repositoryPrefix = "/branches/feature"

    init(copy: SvnDockWorkingCopy) { self.copy = copy }
    var hasPendingUpdate: Bool { pendingUpdate != nil }
    func holdNextUpdate() { shouldHoldUpdate = true }
    func finishPendingUpdate() { pendingUpdate?.resume(); pendingUpdate = nil }
    func failNextBadgeRefresh() { shouldFailBadgeRefresh = true }
    func moveRepository(to prefix: String) { repositoryPrefix = prefix }

    func loadRegisteredWorkingCopies() async throws -> [SvnDockWorkingCopy] { [copy] }
    func status(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockStatusSnapshot {
        statusCalls += 1
        let modified = ["A.swift", "B.swift", "C.swift", "D/one.swift", "D/sub/two.swift", "D2/other.swift"]
            .map { SvnDockStatusEntry(workingCopyID: copy.id, relativePath: $0, nodeKind: .file, status: .modified) }
        return SvnDockStatusSnapshot(entries: modified + [
            .init(workingCopyID: copy.id, relativePath: "D", nodeKind: .directory, status: .modified),
            .init(workingCopyID: copy.id, relativePath: "loose.txt", nodeKind: .file, status: .unversioned)
        ])
    }
    func refreshFinderBadges(for workingCopy: SvnDockWorkingCopy, directoryPaths: [String], preferredPaths: [String]) async throws {
        badgeRefreshes.append(BadgeRefresh(directories: directoryPaths, preferred: preferredPaths))
        if shouldFailBadgeRefresh {
            shouldFailBadgeRefresh = false
            throw unavailable
        }
    }
    func finderTarget(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> SvnDockFinderTarget {
        targetPaths.append(relativePath)
        guard relativePath != "loose.txt" else { throw unavailable }
        let entry = SvnDockStatusEntry(workingCopyID: copy.id, relativePath: relativePath,
            nodeKind: relativePath == "." || relativePath == "D" || relativePath == "D/sub" ? .directory : .file,
            status: relativePath == "src/clean@文本.swift" || relativePath == "." || relativePath == "D/sub" ? .clean : .modified)
        return SvnDockFinderTarget(entry: entry,
            repositoryRelativePath: relativePath == "." ? repositoryPrefix : repositoryPrefix + "/" + relativePath)
    }
    func diff(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> String {
        diffPaths.append(relativePath)
        return ""
    }
    func history(for workingCopy: SvnDockWorkingCopy, relativePaths: [String], limit: Int) async throws -> [SvnDockLogEntry] {
        historyPaths.append(relativePaths)
        return [.init(revision: 9, author: "fixture", date: nil, message: "Change several files")]
    }
    func revisionDetails(revision: Int, in workingCopy: SvnDockWorkingCopy) async throws -> SVNRevisionDetails {
        let changes = (0..<305).map {
            SVNChangedPath(path: "/branches/feature/file-\($0).swift", action: .modified, kind: .file)
        } + [SVNChangedPath(path: "/branches/feature/src/clean@文本.swift", action: .modified, kind: .file)]
        return SVNRevisionDetails(repositoryRootURL: URL(string: "https://example.test/repo")!,
            entry: SVNLogEntry(revision: revision, author: nil, date: nil, message: "fixture"), changes: changes)
    }
    func revisionDiff(revision: Int, change: SVNChangedPath, repositoryRoot: URL, in workingCopy: SvnDockWorkingCopy) async throws -> String {
        change.path
    }
    func commit(workingCopy: SvnDockWorkingCopy, relativePaths: [String], message: String) async throws {
        commitPaths.append(relativePaths)
    }
    func registerWorkingCopy(at url: URL) async throws -> SvnDockWorkingCopy { throw unavailable }
    func unregisterWorkingCopy(id: UUID) async throws { throw unavailable }
    func directoryChildren(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> [SvnDockStatusEntry] { [] }
    func update(workingCopies: [SvnDockWorkingCopy]) async throws {
        if shouldHoldUpdate {
            shouldHoldUpdate = false
            await withCheckedContinuation { pendingUpdate = $0 }
        }
    }
    func add(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func unscheduleAdd(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func cleanupMissingAdditions(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func scheduleMissingDeletion(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func revert(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func resolve(relativePaths: [String], using resolution: SvnDockConflictResolution, in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func addIgnoreRules(_ rules: [SvnDockIgnoreRule], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func cleanup(workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    private var unavailable: SvnDockServiceError { .unavailable("Unsupported Finder fixture target") }
}
