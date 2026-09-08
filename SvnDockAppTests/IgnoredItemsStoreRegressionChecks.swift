import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum IgnoredItemsStoreRegressionChecks {
    @MainActor
    static func run() async throws {
        try await batchIgnoreCapturesSelection()
        try await loadingStaysOnDemandAndSeparate()
        try await obsoleteLoadsCannotReplaceTheSelectedCopy()
        try await confirmationAndRemovalOutcomes()
        try await obsoletePreparationCannotOpenConfirmation()
        print("Ignored items store checks passed: lazy loading, separate counts, stale responses, confirmation and removal outcomes")
    }

    @MainActor
    private static func batchIgnoreCapturesSelection() async throws {
        let service = IgnoredItemsStoreFixtureService()
        await service.enableBatchTargets()
        let store = SvnDockStore(service: service)
        try check(await store.load(), "batch ignore fixture loads")
        let entries = store.entries
        let first = entries.first { $0.relativePath == "new.txt" }!
        let other = entries.first { $0.relativePath == "sub/other.tmp" }!
        let changed = entries.first { $0.relativePath == "source.swift" }!
        let noExtension = entries.first { $0.relativePath == "README" }!
        store.selectedEntryIDs = Set([first, other, changed, noExtension].map(\.id))
        store.requestIgnoreConfirmation(for: first, mode: .name)
        try check(store.pendingIgnoreMessage.contains("忽略 3 项")
                    && store.pendingIgnoreMessage.contains("sub/other.tmp"),
                  "name ignore confirms every selected unversioned item and its parent")
        store.cancelIgnoreConfirmation()
        try check(await service.addedRules.isEmpty, "cancelling does not add rules")
        store.requestIgnoreConfirmation(for: first, mode: .fileExtension)
        try check(store.pendingIgnoreMessage.contains("忽略 2 项"),
                  "extension ignore excludes versioned and extensionless selections")
        store.selectedEntryIDs = [noExtension.id]
        store.confirmIgnore()
        try await waitUntil { store.activeOperation == nil }
        let rules = await service.addedRules
        try check(Set(rules.map(\.targetRelativePath)) == ["new.txt", "sub/other.tmp"],
                  "confirmation captures the original selection before later selection changes")
        try check(Set(rules.map(\.parentRelativePath)) == [".", "sub"]
                    && Set(rules.map(\.pattern)) == ["*.txt", "*.tmp"],
                  "each selected item generates a rule in its own parent")
        store.selectedEntryIDs = [first.id, other.id]
        store.requestIgnoreConfirmation(for: noExtension, mode: .name)
        try check(store.pendingIgnoreMessage.contains("忽略 1 项")
                    && !store.pendingIgnoreMessage.contains("sub/other.tmp"),
                  "right-clicking outside the selection targets only that item")
        store.cancelIgnoreConfirmation()
        let directory = entries.first { $0.relativePath == "build" }!
        let child = entries.first { $0.relativePath == "build/child.tmp" }!
        store.selectedEntryIDs = [directory.id, child.id]
        store.requestIgnoreConfirmation(for: child, mode: .name)
        try check(store.pendingIgnoreMessage.contains("忽略 2 项，生成 1 条规则"),
                  "a selected directory covers its selected descendants")
        store.confirmIgnore()
        try await waitUntil { store.activeOperation == nil }
        let directoryRule = await service.addedRules.last
        try check(directoryRule?.targetRelativePath == "build" && directoryRule?.parentRelativePath == ".",
                  "covered children never add their ignored parent to SVN")
    }

    @MainActor
    private static func loadingStaysOnDemandAndSeparate() async throws {
        let service = IgnoredItemsStoreFixtureService()
        let store = SvnDockStore(service: service)
        try check(await store.load(), "ignored fixture working copies load")
        await store.reloadSelectedWorkingCopy()
        try check(await service.ignoredCalls == 0,
                  "startup and ordinary refresh never load ignored items")
        let counts = store.statusCounts
        let normalPaths = store.entries.map(\.relativePath)
        try check(counts.changed == 1 && counts.unversioned == 1,
                  "the fixture has independent modified and unversioned entries")

        store.statusFilter = .ignored
        try await waitUntil { store.hasLoadedIgnoredEntries && !store.isFilteringStatusEntries }
        try check(store.displayedEntries.map(\.relativePath) == ["build", "cache.tmp"],
                  "the ignored filter shows only its own sorted ignored rows")
        try check(store.statusCounts == counts && store.entries.map(\.relativePath) == normalPaths
                    && store.committableEntries.map(\.relativePath) == ["source.swift"],
                  "ignored rows do not enter change counts, normal status, or commit selection")
        store.selectAllFilteredStatusEntries()
        try check(Set(store.selectedEntries.map(\.relativePath)) == Set(["build", "cache.tmp"]),
                  "ignored rows can be selected through their separate status index")

        store.statusFilter = .all
        try await waitUntil { !store.isFilteringStatusEntries }
        try check(!store.displayedEntries.contains { $0.status == .ignored },
                  "returning to ordinary changes hides ignored rows")
        store.statusFilter = .ignored
        try await waitUntil { !store.isFilteringStatusEntries }
        try check(await service.ignoredCalls == 1, "returning to an already loaded filter reuses its result")
        await store.reloadSelectedWorkingCopy()
        try await waitUntil { store.hasLoadedIgnoredEntries && !store.isLoadingIgnoredEntries }
        try check(await service.ignoredCalls == 2, "local refresh invalidates and reloads an open ignored filter")

        await service.failNextIgnoredLoad()
        store.retryIgnoredEntries()
        try await waitUntil { !store.isLoadingIgnoredEntries && store.ignoredEntriesError != nil }
        try check(!store.hasLoadedIgnoredEntries && store.statusCounts == counts
                    && store.presentedError == nil,
                  "a failed ignored scan has a local retry state without replacing ordinary status")
        store.retryIgnoredEntries()
        try await waitUntil { store.hasLoadedIgnoredEntries && !store.isLoadingIgnoredEntries }
        try check(store.ignoredEntriesError == nil && store.ignoredEntries.count == 2,
                  "a successful retry clears the earlier scan error")
    }

    @MainActor
    private static func obsoleteLoadsCannotReplaceTheSelectedCopy() async throws {
        for failLateResult in [false, true] {
            let service = IgnoredItemsStoreFixtureService()
            let store = SvnDockStore(service: service)
            try check(await store.load(), "late-result fixture loads")
            await service.holdNextIgnoredLoad()
            store.statusFilter = .ignored
            try await waitUntil { await service.hasPendingIgnoredLoad }
            try check(store.isLoadingIgnoredEntries && !store.isSidebarNavigationBlocked,
                      "an ignored scan leaves working-copy navigation available")
            let second = store.workingCopies[1]
            store.selectedWorkingCopyID = second.id
            await store.selectedWorkingCopyDidChange(to: second.id)
            try await waitUntil { store.hasLoadedIgnoredEntries && !store.isFilteringStatusEntries }
            let secondEntries = store.ignoredEntries
            try check(secondEntries.map(\.relativePath) == ["second.cache"]
                        && secondEntries.allSatisfy { $0.workingCopyID == second.id },
                      "the next working copy gets its own ignored rows")
            await service.finishPendingIgnoredLoad(failing: failLateResult)
            try await waitUntil { await service.completedIgnoredCalls == 2 }
            // The obsolete service deliberately ignores cancellation; allow
            // its store task to process the late completion or error.
            for _ in 0..<10 { await Task.yield() }
            try check(store.ignoredEntries == secondEntries && store.ignoredEntriesError == nil
                        && !store.isLoadingIgnoredEntries,
                      "an obsolete result or failure cannot replace a newly selected working copy")
        }
    }

    @MainActor
    private static func confirmationAndRemovalOutcomes() async throws {
        for shouldFail in [false, true] {
            let service = IgnoredItemsStoreFixtureService()
            let store = SvnDockStore(service: service)
            try check(await store.load(), "removal fixture loads")
            store.statusFilter = .ignored
            try await waitUntil { store.hasLoadedIgnoredEntries }
            guard let entry = store.ignoredEntries.first(where: { $0.relativePath == "cache.tmp" }) else {
                throw IgnoredItemsStoreFailure(message: "missing ignored selection")
            }
            await store.requestIgnoreRemoval(for: entry)
            try check(store.isPresentingIgnoreRemovalConfirmation
                        && store.pendingIgnoreRemovalMessage.contains("*.tmp")
                        && store.pendingIgnoreRemovalMessage.contains("保留磁盘文件"),
                      "confirmation describes the actual shared rule and preserved file content")
            try check(await service.removeCalls == 0, "preparing the dialog cannot mutate SVN")
            store.cancelIgnoreRemoval()
            store.confirmIgnoreRemoval()
            try check(await service.removeCalls == 0, "cancelled confirmation cannot later invoke removal")
            try check(!store.isPresentingIgnoreRemovalConfirmation && store.pendingIgnoreRemovalMessage.isEmpty,
                      "cancel clears the prepared operation")

            if shouldFail { await service.failNextRemoval() }
            await store.requestIgnoreRemoval(for: entry)
            store.confirmIgnoreRemoval()
            store.confirmIgnoreRemoval()
            try await waitUntil { !store.isBusy && !store.operationRecords.isEmpty }
            try check(await service.removeCalls == 1, "duplicate confirmation triggers only one mutation")
            if shouldFail {
                try check(store.presentedError != nil && store.statusFilter == .ignored
                            && !store.entries.contains { $0.relativePath == "cache.tmp" },
                          "stale-plan failure retains the ignored context and never pretends the target was restored")
                try check(store.operationRecords.first?.outcome != .success,
                          "a failed removal cannot leave a success operation record")
            } else {
                try await waitUntil { store.statusFilter == .unversioned && !store.isFilteringStatusEntries }
                try check(store.selectedEntries.map(\.relativePath) == ["cache.tmp"]
                            && store.selectedEntries.first?.status == .unversioned,
                          "successful removal selects the actual restored unversioned item")
                try check(store.entries.contains { $0.relativePath == "." && $0.status == .modified }
                            && store.operationRecords.first?.outcome == .success,
                          "the parent property change remains available for commit with a success record")
            }
        }
    }

    @MainActor
    private static func obsoletePreparationCannotOpenConfirmation() async throws {
        let service = IgnoredItemsStoreFixtureService()
        let store = SvnDockStore(service: service)
        try check(await store.load(), "preparation fixture loads")
        store.statusFilter = .ignored
        try await waitUntil { store.hasLoadedIgnoredEntries }
        let entry = store.ignoredEntries[0]
        await service.holdNextPreparation()
        let preparation = Task { await store.requestIgnoreRemoval(for: entry) }
        try await waitUntil { await service.hasPendingPreparation }
        let second = store.workingCopies[1]
        store.selectedWorkingCopyID = second.id
        await service.finishPendingPreparation()
        await preparation.value
        try check(!store.isPresentingIgnoreRemovalConfirmation && store.presentedError == nil,
                  "an obsolete rule preview cannot open a dialog in another working copy")
        try check(await service.removeCalls == 0, "working-copy switches never confirm a pending preview")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw IgnoredItemsStoreFailure(message: message) }
    }

    @MainActor
    private static func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard clock.now < deadline else { throw IgnoredItemsStoreFailure(message: "ignored store operation timed out") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private struct IgnoredItemsStoreFailure: Error { let message: String }

private actor IgnoredItemsStoreFixtureService: SvnDockServicing {
    private let first = SvnDockWorkingCopy(name: "Alpha", rootURL: URL(fileURLWithPath: "/fixture/ignored-alpha"))
    private let second = SvnDockWorkingCopy(name: "Beta", rootURL: URL(fileURLWithPath: "/fixture/ignored-beta"))
    private var shouldFailLoad = false
    private var shouldHoldLoad = false
    private var shouldFailRemoval = false
    private var shouldHoldPreparation = false
    private var didRemove = false
    private var batchTargets = false
    private(set) var addedRules: [SvnDockIgnoreRule] = []
    func enableBatchTargets() { batchTargets = true }
    private var pendingLoad: CheckedContinuation<Bool, Never>?
    private var pendingPreparation: CheckedContinuation<Void, Never>?
    private(set) var ignoredCalls = 0
    private(set) var completedIgnoredCalls = 0
    private(set) var removeCalls = 0

    var hasPendingIgnoredLoad: Bool { pendingLoad != nil }
    var hasPendingPreparation: Bool { pendingPreparation != nil }
    func failNextIgnoredLoad() { shouldFailLoad = true }
    func holdNextIgnoredLoad() { shouldHoldLoad = true }
    func failNextRemoval() { shouldFailRemoval = true }
    func holdNextPreparation() { shouldHoldPreparation = true }
    func finishPendingIgnoredLoad(failing: Bool) { pendingLoad?.resume(returning: failing); pendingLoad = nil }
    func finishPendingPreparation() { pendingPreparation?.resume(); pendingPreparation = nil }

    func loadRegisteredWorkingCopies() async throws -> [SvnDockWorkingCopy] { [first, second] }
    func status(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockStatusSnapshot {
        var entries = [entry("source.swift", status: .modified, copy: workingCopy),
                       entry("new.txt", status: .unversioned, copy: workingCopy)]
        if batchTargets {
            entries += [entry("sub/other.tmp", status: .unversioned, copy: workingCopy),
                        entry("README", status: .unversioned, copy: workingCopy),
                        entry("build", status: .unversioned, copy: workingCopy, kind: .directory),
                        entry("build/child.tmp", status: .unversioned, copy: workingCopy)]
        }
        if didRemove && workingCopy.id == first.id {
            entries.append(entry("cache.tmp", status: .unversioned, copy: workingCopy))
            entries.append(entry(".", status: .modified, copy: workingCopy, kind: .directory))
        }
        return SvnDockStatusSnapshot(entries: entries)
    }
    func ignoredEntries(for workingCopy: SvnDockWorkingCopy) async throws -> [SvnDockStatusEntry] {
        ignoredCalls += 1
        defer { completedIgnoredCalls += 1 }
        if shouldHoldLoad {
            shouldHoldLoad = false
            let fail = await withCheckedContinuation { pendingLoad = $0 }
            if fail { throw unavailable }
        } else if shouldFailLoad {
            shouldFailLoad = false
            throw unavailable
        }
        if workingCopy.id == second.id { return [entry("second.cache", status: .ignored, copy: workingCopy)] }
        return [entry("build", status: .ignored, copy: workingCopy, kind: .directory)]
            + (didRemove ? [] : [entry("cache.tmp", status: .ignored, copy: workingCopy)])
            + [entry("wrong-status", status: .unversioned, copy: workingCopy),
               entry("wrong-copy", status: .ignored, copy: second)]
    }
    func prepareIgnoreRemoval(for selected: SvnDockStatusEntry, in workingCopy: SvnDockWorkingCopy) async throws -> SvnDockIgnoreRemovalPlan {
        if shouldHoldPreparation {
            shouldHoldPreparation = false
            await withCheckedContinuation { pendingPreparation = $0 }
        }
        return SvnDockIgnoreRemovalPlan(workingCopyID: workingCopy.id, workingCopyRootURL: workingCopy.rootURL,
            targetRelativePath: selected.relativePath, parentRelativePath: ".", patterns: ["*.tmp"],
            originalPropertyValue: "*.tmp\nkeep.cache\n", updatedPropertyValue: "keep.cache\n",
            affectedSiblingPaths: [selected.relativePath])
    }
    func removeIgnoreRule(_ plan: SvnDockIgnoreRemovalPlan, in workingCopy: SvnDockWorkingCopy) async throws {
        removeCalls += 1
        if shouldFailRemoval {
            shouldFailRemoval = false
            throw SvnDockIgnoreRemovalError.stalePlan
        }
        didRemove = true
    }

    private func entry(_ path: String, status: SvnDockStatusKind, copy: SvnDockWorkingCopy,
                       kind: SvnDockNodeKind = .file) -> SvnDockStatusEntry {
        SvnDockStatusEntry(workingCopyID: copy.id, relativePath: path, nodeKind: kind, status: status)
    }
    func registerWorkingCopy(at url: URL) async throws -> SvnDockWorkingCopy { throw unavailable }
    func unregisterWorkingCopy(id: UUID) async throws { throw unavailable }
    func directoryChildren(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> [SvnDockStatusEntry] { [] }
    func diff(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> String { throw unavailable }
    func history(for workingCopy: SvnDockWorkingCopy, relativePaths: [String], limit: Int) async throws -> [SvnDockLogEntry] { [] }
    func revisionDetails(revision: Int, in workingCopy: SvnDockWorkingCopy) async throws -> SVNRevisionDetails { throw unavailable }
    func revisionDiff(revision: Int, change: SVNChangedPath, repositoryRoot: URL, in workingCopy: SvnDockWorkingCopy) async throws -> String { throw unavailable }
    func update(workingCopies: [SvnDockWorkingCopy]) async throws { throw unavailable }
    func commit(workingCopy: SvnDockWorkingCopy, relativePaths: [String], message: String) async throws { throw unavailable }
    func add(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func unscheduleAdd(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func cleanupMissingAdditions(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func scheduleMissingDeletion(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func revert(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func resolve(relativePaths: [String], using resolution: SvnDockConflictResolution, in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func addIgnoreRules(_ rules: [SvnDockIgnoreRule], in workingCopy: SvnDockWorkingCopy) async throws { addedRules += rules }
    func cleanup(workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    private var unavailable: SvnDockServiceError { .unavailable("Fixture ignored status is unavailable") }
}
