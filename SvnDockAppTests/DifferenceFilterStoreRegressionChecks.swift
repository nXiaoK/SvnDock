import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

@MainActor
enum DifferenceFilterStoreRegressionChecks {
    static func run() async throws {
        try await filteringPreservesStatusAndCommitChoices()
        try await unavailableComparisonsRemainVisibleAndRetry()
        try await disablingRejectsLateResults()
        try await refreshAndSelectionRejectLateResults()
        try await mutationsInvalidateAndResumeClassification()
        try await unrelatedPresentationsDoNotStrandComparisons()
        print("Difference filter store checks passed: conservative scope, selections, retry, cancellation and stale results")
    }

    static func filteringPreservesStatusAndCommitChoices() async throws {
        let service = DifferenceFilterFixtureService(comprehensive: true)
        let store = SvnDockStore(service: service)
        try check(await store.load(), "the difference-filter fixture loads")
        try check(store.differenceFilter == .all && !store.isCheckingDifferences,
                  "difference filtering is disabled by default")
        await settle()
        try check(await service.requests.isEmpty, "ordinary status loading does not read file differences")
        let originalEntries = store.entries
        let originalCounts = store.statusCounts
        let originalCommittable = store.committableEntries
        store.selectedEntryIDs = Set(originalEntries.map(\.id))

        store.differenceFilter = .hideLineEndings
        try await waitUntil { await service.requests.count == 4 && !store.isCheckingDifferences && !store.isFilteringStatusEntries }
        let comparedPaths = Set(await service.requests.map(\.path))
        try check(comparedPaths == ["line-endings.txt", "whitespace.txt", "real.txt", "properties.txt"],
                  "only modified regular files without local or remote conflicts are classified")
        let lineEndingID = try entry("line-endings.txt", in: store).id
        let whitespaceID = try entry("whitespace.txt", in: store).id
        try check(store.hiddenDifferenceCount == 1 && store.uncheckedDifferenceCount == 0,
                  "the line-ending mode hides only a confirmed line-ending-only change")
        try check(!store.displayedEntries.contains { $0.id == lineEndingID }
                    && store.displayedEntries.contains { $0.id == whitespaceID },
                  "ordinary whitespace changes remain visible under the narrower line-ending filter")
        try check(!store.selectedEntryIDs.contains(lineEndingID), "a hidden file cannot remain selected for an action")

        store.differenceFilter = .hideWhitespace
        try await waitUntil { !store.isCheckingDifferences && !store.isFilteringStatusEntries && store.hiddenDifferenceCount == 2 }
        try check(await service.requests.count == 4, "changing modes reuses confirmed comparisons in the current snapshot")
        let protectedPaths: Set<String> = ["real.txt", "properties.txt", "text-conflict.txt", "property-conflict.txt",
                                            "remote-conflict.txt", "link", "directory", "added.txt", "deleted.txt",
                                            "replaced.txt", "unversioned.txt", "missing.txt"]
        try check(Set(store.displayedEntries.map(\.relativePath)) == protectedPaths,
                  "real changes, properties, conflicts, links and structural changes stay visible")
        try check(store.entries == originalEntries && store.statusCounts == originalCounts
                    && store.committableEntries == originalCommittable,
                  "the display filter cannot erase authoritative status, counters or committable files")
        store.selectAllFilteredStatusEntries()
        try check(store.selectedEntryIDs == Set(store.displayedEntries.map(\.id)),
                  "select-all operates on the filtered list without selecting hidden changes")

        store.searchQuery = "real.txt"
        try await waitUntil { !store.isFilteringStatusEntries && store.displayedEntries.count == 1 }
        try check(store.hiddenDifferenceCount == 2, "the hidden count describes the snapshot independently of text search")
        store.searchQuery = ""
        try await waitUntil { !store.isFilteringStatusEntries && store.displayedEntries.count == protectedPaths.count }
        store.selectedEntryIDs = []
        store.requestCommit()
        try check(store.isPresentingCommit && store.commitInitialSelectedEntryIDs == nil
                    && store.commitInitiallyExcludedEntryIDs == [lineEndingID, whitespaceID],
                  "ordinary commit opening captures hidden files as initial exclusions without removing reviewable entries")
        let savedDraft = SvnDockCommitDraft(message: "Keep the review message",
                                           includedRelativePaths: ["line-endings.txt", "real.txt"],
                                           previewRelativePath: "line-endings.txt")
        let realID = try entry("real.txt", in: store).id
        try check(SvnDockCommitDraft.initialIncludedEntryIDs(
            entries: store.committableEntries, selectedEntryIDs: [], savedDraft: savedDraft,
            excludedEntryIDs: store.commitInitiallyExcludedEntryIDs
        ) == [realID], "a restored draft cannot silently reselect hidden changes")
        try check(SvnDockCommitDraft.initialIncludedEntryIDs(
            entries: [try entry("line-endings.txt", in: store)], selectedEntryIDs: [], savedDraft: nil,
            excludedEntryIDs: store.commitInitiallyExcludedEntryIDs
        ).isEmpty, "a review with every file hidden remains unselected instead of falling back to select-all")
        try check(SvnDockCommitDraft.initialIncludedEntryIDs(
            entries: store.committableEntries, selectedEntryIDs: [], savedDraft: savedDraft,
            explicitEntryIDs: [lineEndingID], excludedEntryIDs: store.commitInitiallyExcludedEntryIDs
        ) == [lineEndingID], "an explicit Finder scope overrides both draft choices and workspace exclusions")
        store.differenceFilter = .all
        try check(store.commitInitiallyExcludedEntryIDs == [lineEndingID, whitespaceID],
                  "an open commit sheet keeps its captured initial exclusions if the filter changes")
        store.cancelCommit()
        try check(store.commitInitiallyExcludedEntryIDs.isEmpty, "closing the commit sheet clears its captured exclusions")
        store.requestCommit()
        try check(store.commitInitiallyExcludedEntryIDs.isEmpty, "opening commit with the filter disabled has no hidden exclusions")
        store.cancelCommit()

        store.differenceFilter = .hideWhitespace
        try await waitUntil { store.hiddenDifferenceCount == 2 && !store.isFilteringStatusEntries }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("svndock-difference-claim-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let shared = try FinderSharedStore(directoryURL: temporary)
        let coordinator = try FinderCommandQueueCoordinator(directoryURL: temporary)
        let copy = try unwrap(store.selectedWorkingCopy)
        let command = FinderCommand(kind: .commit, paths: [copy.rootURL.appendingPathComponent("line-endings.txt").path],
                                    workingCopyRoot: copy.rootURL.path)
        _ = try await shared.enqueue(command)
        let claim = try unwrap(try await coordinator.claimCommand(id: command.id, as: .application))
        store.selectedEntryIDs = [lineEndingID]
        store.requestCommit(allowDuringFinderRouting: true, finderClaim: claim)
        try check(store.isPresentingCommit && store.commitInitialSelectedEntryIDs == [lineEndingID]
                    && store.commitInitiallyExcludedEntryIDs.isEmpty,
                  "an explicit Finder commit keeps its requested file even when the workspace filter hides that difference")
        store.cancelCommit()
        store.differenceFilter = .all
    }

    static func unavailableComparisonsRemainVisibleAndRetry() async throws {
        let service = DifferenceFilterFixtureService(comprehensive: true)
        await service.failOnce(path: "line-endings.txt")
        await service.setKind(.unknown, for: "whitespace.txt")
        let store = SvnDockStore(service: service)
        _ = await store.load()
        store.differenceFilter = .hideWhitespace
        try await waitUntil { await service.requests.count == 4 && !store.isCheckingDifferences }
        try check(store.hiddenDifferenceCount == 0 && store.uncheckedDifferenceCount == 2,
                  "both failed reads and unsupported comparisons remain visible and are counted as unchecked")
        try check(store.displayedEntries.count == store.entries.count && store.presentedError == nil,
                  "background comparison failure neither hides a file nor interrupts review with a modal error")
        await service.setKind(.whitespaceOnly, for: "whitespace.txt")
        store.retryDifferenceClassification()
        try await waitUntil { await service.requests.count == 6 && !store.isCheckingDifferences && !store.isFilteringStatusEntries }
        let retriedPaths = Array(await service.requests.dropFirst(4).map(\.path))
        try check(Set(retriedPaths) == ["line-endings.txt", "whitespace.txt"]
                    && store.hiddenDifferenceCount == 2 && store.uncheckedDifferenceCount == 0,
                  "explicit retry revisits only unchecked paths and publishes their newly confirmed classifications")
        store.differenceFilter = .all
    }

    static func disablingRejectsLateResults() async throws {
        let service = DifferenceFilterFixtureService()
        let store = SvnDockStore(service: service)
        _ = await store.load()
        await service.holdNextClassification()
        store.differenceFilter = .hideLineEndings
        try await waitUntil { await service.pendingClassificationIndices == [0] }
        try check(store.isCheckingDifferences && !store.isBusy && store.displayedEntries.count == 1,
                  "a pending comparison leaves its unverified row visible and does not block ordinary interaction")
        store.differenceFilter = .all
        try check(!store.isCheckingDifferences && store.hiddenDifferenceCount == 0 && store.displayedEntries.count == 1,
                  "disabling the filter stops its loading indicator and shows all changes immediately")
        await service.finishClassification(at: 0, kind: .lineEndingsOnly)
        try await waitUntil { await service.completedIndices.contains(0) }
        await settle()
        try check(await service.cancelledIndices.contains(0), "disabling propagates cancellation to the active service task")
        try check(store.displayedEntries.count == 1 && store.hiddenDifferenceCount == 0,
                  "a non-cooperative late comparison cannot republish a disabled filter")
        await service.setKind(.substantive, for: "line-endings.txt")
        store.differenceFilter = .hideLineEndings
        try await waitUntil { await service.requests.count == 2 && !store.isCheckingDifferences }
        try check(store.hiddenDifferenceCount == 0 && store.displayedEntries.count == 1,
                  "re-enabling compares an interrupted path again instead of caching its cancelled result")
        store.differenceFilter = .all
    }

    static func refreshAndSelectionRejectLateResults() async throws {
        let service = DifferenceFilterFixtureService()
        let store = SvnDockStore(service: service)
        _ = await store.load()
        await service.holdNextClassification()
        store.differenceFilter = .hideLineEndings
        try await waitUntil { await service.pendingClassificationIndices == [0] }
        await service.setKind(.substantive, for: "line-endings.txt")
        await store.reloadSelectedWorkingCopy()
        try await waitUntil { await service.requests.count == 2 && !store.isCheckingDifferences }
        await service.finishClassification(at: 0, kind: .lineEndingsOnly)
        try await waitUntil { await service.completedIndices.contains(0) }
        await settle()
        try check(await service.cancelledIndices.contains(0), "refresh cancels comparison of the preceding status snapshot")
        try check(store.hiddenDifferenceCount == 0 && store.displayedEntries.count == 1,
                  "a late result for the same file cannot override the refreshed snapshot's substantive change")

        await service.holdNextClassification()
        await store.reloadSelectedWorkingCopy()
        try await waitUntil { await service.pendingClassificationIndices == [2] }
        let second = try unwrap(store.workingCopies.last)
        await store.selectWorkingCopyFromMenu(second.id)
        try await waitUntil { await service.requests.count == 4 && !store.isCheckingDifferences }
        await service.finishClassification(at: 2, kind: .lineEndingsOnly)
        try await waitUntil { await service.completedIndices.contains(2) }
        await settle()
        try check(await service.cancelledIndices.contains(2), "switching working copies cancels the old classifier")
        try check(store.selectedWorkingCopyID == second.id && store.hiddenDifferenceCount == 0
                    && store.displayedEntries.count == 1 && store.displayedEntries.first?.workingCopyID == second.id,
                  "late classification cannot hide or replace the current working copy's same-named file")
        store.differenceFilter = .all
    }

    static func mutationsInvalidateAndResumeClassification() async throws {
        let service = DifferenceFilterFixtureService()
        let store = SvnDockStore(service: service)
        _ = await store.load()
        store.differenceFilter = .hideLineEndings
        try await waitUntil { store.hiddenDifferenceCount == 1 && !store.isCheckingDifferences }
        await service.holdNextUpdate()
        let update = Task { await store.updateSelectedWorkingCopy() }
        try await waitUntil { await service.hasPendingUpdate }
        try check(store.isBusy && store.hiddenDifferenceCount == 0 && !store.isCheckingDifferences,
                  "a mutation invalidates old classifications and pauses background comparisons")
        store.differenceFilter = .hideWhitespace
        await settle()
        try check(await service.requests.count == 1, "changing the filter during a mutation cannot start a concurrent comparison")
        await service.setKind(.substantive, for: "line-endings.txt")
        await service.finishUpdate()
        await update.value
        try await waitUntil { await service.requests.count == 2 && !store.isCheckingDifferences && !store.isFilteringStatusEntries }
        try check(!store.isBusy && store.hiddenDifferenceCount == 0 && store.displayedEntries.count == 1,
                  "classification resumes on the post-mutation snapshot and exposes a newly substantive edit")
        try check(await service.updateCount == 1, "resuming comparison never repeats the mutation")
        store.differenceFilter = .all
    }

    static func unrelatedPresentationsDoNotStrandComparisons() async throws {
        let service = DifferenceFilterFixtureService()
        let store = SvnDockStore(service: service)
        _ = await store.load()
        await service.holdNextClassification()
        store.differenceFilter = .hideLineEndings
        try await waitUntil { await service.pendingClassificationIndices == [0] }
        store.presentedError = .init(title: "Fixture notice", message: "An unrelated operation failed")
        store.isPresentingRevertConfirmation = true
        await service.finishClassification(at: 0, kind: .lineEndingsOnly)
        try await waitUntil { !store.isCheckingDifferences }
        store.presentedError = nil
        store.isPresentingRevertConfirmation = false
        try await waitUntil { !store.isFilteringStatusEntries }
        try check(store.hiddenDifferenceCount == 1 && store.displayedEntries.isEmpty,
                  "an unrelated error or cancelled confirmation cannot strand an otherwise valid read-only comparison")
        store.differenceFilter = .all
    }

    private static func entry(_ path: String, in store: SvnDockStore) throws -> SvnDockStatusEntry {
        try unwrap(store.entries.first { $0.relativePath == path })
    }

    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw DifferenceFilterFixtureFailure(message: "missing difference-filter fixture") }
        return value
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw DifferenceFilterFixtureFailure(message: message) }
    }

    private static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private static func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !(await condition()) {
            guard clock.now < deadline else { throw DifferenceFilterFixtureFailure(message: "difference-filter operation timed out") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private struct DifferenceFilterFixtureFailure: Error { let message: String }

private actor DifferenceFilterFixtureService: SvnDockServicing {
    struct Request: Sendable { let copyID: UUID; let path: String }
    private let first = SvnDockWorkingCopy(name: "Alpha", rootURL: URL(fileURLWithPath: "/fixture/difference-alpha"))
    private let second = SvnDockWorkingCopy(name: "Beta", rootURL: URL(fileURLWithPath: "/fixture/difference-beta"))
    private let comprehensive: Bool
    private var kinds: [String: SVNLocalDifferenceKind] = [
        "line-endings.txt": .lineEndingsOnly, "whitespace.txt": .whitespaceOnly,
        "real.txt": .substantive, "properties.txt": .substantive
    ]
    private var failOncePaths: Set<String> = []
    private var shouldHoldClassification = false
    private var classifications: [Int: CheckedContinuation<SVNLocalDifferenceKind, Never>] = [:]
    private var shouldHoldUpdate = false
    private var pendingUpdate: CheckedContinuation<Void, Never>?
    private(set) var requests: [Request] = []
    private(set) var completedIndices: Set<Int> = []
    private(set) var cancelledIndices: Set<Int> = []
    private(set) var updateCount = 0

    init(comprehensive: Bool = false) { self.comprehensive = comprehensive }
    var pendingClassificationIndices: Set<Int> { Set(classifications.keys) }
    var hasPendingUpdate: Bool { pendingUpdate != nil }
    func holdNextClassification() { shouldHoldClassification = true }
    func setKind(_ kind: SVNLocalDifferenceKind, for path: String) { kinds[path] = kind }
    func failOnce(path: String) { failOncePaths.insert(path) }
    func holdNextUpdate() { shouldHoldUpdate = true }
    func finishUpdate() { pendingUpdate?.resume(); pendingUpdate = nil }
    func finishClassification(at index: Int, kind: SVNLocalDifferenceKind) {
        classifications.removeValue(forKey: index)?.resume(returning: kind)
    }

    func loadRegisteredWorkingCopies() async throws -> [SvnDockWorkingCopy] { [first, second] }
    func status(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockStatusSnapshot {
        let id = workingCopy.id
        var entries: [SvnDockStatusEntry] = [
            .init(workingCopyID: id, relativePath: "line-endings.txt", nodeKind: .file, status: .modified)
        ]
        if comprehensive {
            entries += [
                .init(workingCopyID: id, relativePath: "whitespace.txt", nodeKind: .file, status: .modified),
                .init(workingCopyID: id, relativePath: "real.txt", nodeKind: .file, status: .modified),
                .init(workingCopyID: id, relativePath: "properties.txt", nodeKind: .file, status: .modified),
                .init(workingCopyID: id, relativePath: "text-conflict.txt", nodeKind: .file, status: .conflicted),
                .init(workingCopyID: id, relativePath: "property-conflict.txt", nodeKind: .file, status: .modified, conflictKinds: [.property]),
                .init(workingCopyID: id, relativePath: "remote-conflict.txt", nodeKind: .file, status: .modified, repositoryStatus: .conflicted),
                .init(workingCopyID: id, relativePath: "link", nodeKind: .file, isSymbolicLink: true, status: .modified),
                .init(workingCopyID: id, relativePath: "directory", nodeKind: .directory, status: .modified),
                .init(workingCopyID: id, relativePath: "added.txt", nodeKind: .file, status: .added),
                .init(workingCopyID: id, relativePath: "deleted.txt", nodeKind: .file, status: .deleted),
                .init(workingCopyID: id, relativePath: "replaced.txt", nodeKind: .file, status: .replaced),
                .init(workingCopyID: id, relativePath: "unversioned.txt", nodeKind: .file, status: .unversioned),
                .init(workingCopyID: id, relativePath: "missing.txt", nodeKind: .file, status: .missing)
            ]
        }
        return SvnDockStatusSnapshot(entries: entries)
    }

    func classifyLocalDifference(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> SVNLocalDifferenceKind {
        let index = requests.count
        requests.append(Request(copyID: workingCopy.id, path: relativePath))
        defer {
            completedIndices.insert(index)
            if Task.isCancelled { cancelledIndices.insert(index) }
        }
        if failOncePaths.remove(relativePath) != nil { throw unsupported }
        if shouldHoldClassification {
            shouldHoldClassification = false
            // Intentionally ignore cancellation until the test releases this
            // read, so publication must also verify snapshot ownership.
            return await withCheckedContinuation { classifications[index] = $0 }
        }
        return kinds[relativePath] ?? .unknown
    }

    func update(workingCopies: [SvnDockWorkingCopy]) async throws {
        updateCount += 1
        if shouldHoldUpdate {
            shouldHoldUpdate = false
            await withCheckedContinuation { pendingUpdate = $0 }
        }
    }
    func registerWorkingCopy(at url: URL) async throws -> SvnDockWorkingCopy { throw unsupported }
    func unregisterWorkingCopy(id: UUID) async throws { throw unsupported }
    func directoryChildren(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> [SvnDockStatusEntry] { [] }
    func diff(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> String { throw unsupported }
    func history(for workingCopy: SvnDockWorkingCopy, relativePaths: [String], limit: Int) async throws -> [SvnDockLogEntry] { [] }
    func revisionDetails(revision: Int, in workingCopy: SvnDockWorkingCopy) async throws -> SVNRevisionDetails { throw unsupported }
    func revisionDiff(revision: Int, change: SVNChangedPath, repositoryRoot: URL, in workingCopy: SvnDockWorkingCopy) async throws -> String { throw unsupported }
    func commit(workingCopy: SvnDockWorkingCopy, relativePaths: [String], message: String) async throws { throw unsupported }
    func add(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func unscheduleAdd(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func cleanupMissingAdditions(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func scheduleMissingDeletion(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func revert(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func resolve(relativePaths: [String], using resolution: SvnDockConflictResolution, in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func addIgnoreRules(_ rules: [SvnDockIgnoreRule], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func cleanup(workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    private var unsupported: DifferenceFilterFixtureFailure { DifferenceFilterFixtureFailure(message: "unavailable fixture comparison") }
}
