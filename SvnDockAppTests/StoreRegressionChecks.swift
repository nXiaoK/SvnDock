import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum StoreRegressionChecks {
    @MainActor
    static func failedStatusCannotAppearCleanOrRetainActions() async throws {
        let service = ControlledStoreService()
        let store = SvnDockStore(service: service)
        try check(!store.hasLoadedStatus, "an unscanned store cannot claim a clean state")
        await service.failNextStatus()
        let loaded = await store.load()
        store.presentedError = nil
        try check(!loaded && !store.hasLoadedStatus && store.statusRecoveryMessage != nil,
                  "initial status failure remains unknown after dismissing the error")
        try check(store.entries.isEmpty && !store.hasPendingChanges && !store.isBusy,
                  "a failed scan leaves no actionable snapshot and permits retry")

        await store.reloadSelectedWorkingCopy()
        try check(store.hasLoadedStatus && store.statusRecoveryMessage == nil,
                  "a successful retry restores a trusted snapshot")
        let oldEntry = try unwrap(store.entries.first { $0.nodeKind == .file })
        await store.updateSelectedWorkingCopy()
        store.presentedError = nil
        try check(!store.hasLoadedStatus && store.statusRecoveryMessage != nil && store.entries.isEmpty,
                  "an update followed by scan failure invalidates the pre-update modifications")
        try check(store.selectedWorkingCopy?.lastRefreshedAt == nil
                    && store.selectedWorkingCopy?.counts == .zero,
                  "menus cannot present old counts as a current status")
        store.selectedEntryIDs = [oldEntry.id]
        store.requestCommit()
        try check(!store.hasPendingChanges && !store.isPresentingCommit && store.selectedEntries.isEmpty,
                  "stale file identifiers cannot reopen commit or selected-file actions")
        await store.reloadSelectedWorkingCopy()
        try check(store.hasLoadedStatus && store.statusRecoveryMessage == nil
                    && store.entries.first { $0.id == oldEntry.id }?.status == .conflicted,
                  "retry publishes the actual conflict created by the update")
        try check(await service.updateCount == 1, "state recovery never repeats the mutation")

        await service.failNextStatus(cancelled: true)
        await store.reloadSelectedWorkingCopy()
        try check(!store.hasLoadedStatus && store.statusRecoveryMessage != nil && store.entries.isEmpty,
                  "a cancelled current scan also leaves an explicit unknown state")
        await store.reloadSelectedWorkingCopy()
        try check(store.hasLoadedStatus && store.statusRecoveryMessage == nil,
                  "a cancelled scan can be retried normally")
    }

    @MainActor
    static func selectionCancelsDiff() async throws {
        let service = ControlledStoreService()
        let store = SvnDockStore(service: service)
        await store.load()
        let entry = try unwrap(store.entries.first)
        store.selectedEntryIDs = [entry.id]
        let first = Task { await store.loadDiffForSelection() }
        try await waitUntil { await service.diffRequestCount == 1 }
        store.selectedEntryIDs = []
        try check(!store.isLoadingDiff && store.diffText.isEmpty, "selection clears diff immediately")
        await service.finishDiff()
        let succeeded = await first.value
        try check(!succeeded, "obsolete diff cannot publish")
        let cancelled = await service.diffWasCancelled
        try check(cancelled, "selection cancellation reaches the diff service")

        store.selectedEntryIDs = [entry.id]
        let hidden = Task { await store.loadDiffForSelection() }
        try await waitUntil { await service.diffRequestCount == 2 }
        store.inspectorTab = .information
        await service.finishDiff()
        _ = await hidden.value
        let hiddenCancelled = await service.diffWasCancelled
        try check(hiddenCancelled && !store.isLoadingDiff && store.diffText.isEmpty,
                  "hidden diff releases content and cancels work")
    }

    @MainActor
    static func directoryRetryRejectsOldError() async throws {
        let service = ControlledStoreService()
        let store = SvnDockStore(service: service)
        await store.load()
        let directory = try unwrap(store.entries.first { $0.nodeKind == .directory })
        store.toggleDirectoryExpansion(for: directory)
        try await waitUntil { await service.directoryRequestCount == 1 }
        store.retryDirectoryLoad(for: directory)
        try await waitUntil { await service.directoryRequestCount == 2 }
        await service.failDirectory(at: 0)
        try await waitUntil { await service.finishedDirectoryCount == 1 }
        // Allow the cancelled caller to return to the store before checking.
        for _ in 0..<20 { await Task.yield() }
        try check(store.isLoadingDirectory(directory), "old error cannot clear the retry's loading state")
        try check(store.directoryError(for: directory) == nil, "old error cannot replace the retry")
        await service.finishDirectory(at: 1)
        try await waitUntil { @MainActor in !store.isLoadingDirectory(directory) }
        try check(store.visibleDirectoryChildren(for: directory).count == 1, "retry publishes its own children")
        try check(store.directoryError(for: directory) == nil, "successful retry clears errors")
    }

    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw RegressionFailure(message: message) }
    }

    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw RegressionFailure(message: "missing fixture") }
        return value
    }

    @MainActor
    private static func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard clock.now < deadline else { throw RegressionFailure(message: "timed out waiting for test operation") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private struct RegressionFailure: Error { let message: String }

private actor ControlledStoreService: SvnDockServicing {
    let copy = SvnDockWorkingCopy(name: "fixture", rootURL: URL(fileURLWithPath: "/tmp/svndock-store-fixture"))
    var diffRequestCount = 0
    var diffWasCancelled = false
    var diffContinuation: CheckedContinuation<String, Never>?
    var directoryRequestCount = 0
    var finishedDirectoryCount = 0
    var directoryContinuations: [Int: CheckedContinuation<[SvnDockStatusEntry], Error>] = [:]
    private var nextStatusFailure: Bool?
    private var fileStatus: SvnDockStatusKind = .modified
    private(set) var updateCount = 0
    func failNextStatus(cancelled: Bool = false) { nextStatusFailure = cancelled }
    func loadRegisteredWorkingCopies() async throws -> [SvnDockWorkingCopy] { [copy] }
    func status(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockStatusSnapshot {
        if let cancelled = nextStatusFailure {
            nextStatusFailure = nil
            if cancelled { throw CancellationError() }
            throw RegressionFailure(message: "status fixture is unavailable")
        }
        return SvnDockStatusSnapshot(entries: [
            .init(workingCopyID: copy.id, relativePath: "file.txt", nodeKind: .file, status: fileStatus),
            .init(workingCopyID: copy.id, relativePath: "folder", nodeKind: .directory, status: .unversioned)
        ])
    }
    func diff(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> String {
        diffRequestCount += 1
        let text = await withCheckedContinuation { diffContinuation = $0 }
        diffWasCancelled = Task.isCancelled
        return text
    }
    func finishDiff() { diffContinuation?.resume(returning: "obsolete diff"); diffContinuation = nil }
    func directoryChildren(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> [SvnDockStatusEntry] {
        let index = directoryRequestCount
        directoryRequestCount += 1
        defer { finishedDirectoryCount += 1 }
        return try await withCheckedThrowingContinuation { directoryContinuations[index] = $0 }
    }
    func failDirectory(at index: Int) {
        directoryContinuations.removeValue(forKey: index)?.resume(throwing: RegressionFailure(message: "old read failed"))
    }
    func finishDirectory(at index: Int) {
        directoryContinuations.removeValue(forKey: index)?.resume(returning: [
            .init(workingCopyID: copy.id, relativePath: "folder/child", nodeKind: .file, status: .unversioned)
        ])
    }
    func registerWorkingCopy(at url: URL) async throws -> SvnDockWorkingCopy { throw unsupported }
    func unregisterWorkingCopy(id: UUID) async throws { throw unsupported }
    func history(for workingCopy: SvnDockWorkingCopy, relativePaths: [String], limit: Int) async throws -> [SvnDockLogEntry] { throw unsupported }
    func revisionDetails(revision: Int, in workingCopy: SvnDockWorkingCopy) async throws -> SVNRevisionDetails { throw unsupported }
    func revisionDiff(revision: Int, change: SVNChangedPath, repositoryRoot: URL, in workingCopy: SvnDockWorkingCopy) async throws -> String { throw unsupported }
    func update(workingCopies: [SvnDockWorkingCopy]) async throws {
        updateCount += 1
        fileStatus = .conflicted
        nextStatusFailure = false
    }
    func commit(workingCopy: SvnDockWorkingCopy, relativePaths: [String], message: String) async throws { throw unsupported }
    func add(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func unscheduleAdd(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func cleanupMissingAdditions(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func scheduleMissingDeletion(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func revert(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func resolve(relativePaths: [String], using resolution: SvnDockConflictResolution, in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func addIgnoreRules(_ rules: [SvnDockIgnoreRule], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func cleanup(workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    private var unsupported: RegressionFailure { RegressionFailure(message: "unexpected service call") }
}
