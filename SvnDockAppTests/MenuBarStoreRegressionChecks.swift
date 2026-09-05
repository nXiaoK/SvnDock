import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum MenuBarStoreRegressionChecks {
    @MainActor
    static func run() async throws {
        try await startupSurvivesWindowCancellation()
        try await failedStartupCanRetry()
        try await menuSelectionLoadsWithoutAnObserver()
        try await menuSelectionRejectsStaleResults()
    }

    @MainActor
    private static func startupSurvivesWindowCancellation() async throws {
        let service = MenuBarStoreService(holdsInitialLoad: true)
        let store = SvnDockStore(service: service)
        let firstWindow = Task { await store.startIfNeeded() }
        try await waitUntil { await service.loadCount == 1 }
        let secondWindow = Task { await store.startIfNeeded() }
        firstWindow.cancel()
        await service.finishInitialLoad()
        await firstWindow.value
        await secondWindow.value
        try check(await service.loadCount == 1, "concurrent windows share one startup load")
        try check(await service.statusRequests.count == 1, "startup scans the selected working copy once")
        try check(await !service.loadWasCancelled, "closing the first window does not cancel store startup")

        let entry = try unwrap(store.entries.first)
        store.selectedEntryIDs = [entry.id]
        store.isPresentingCommit = true
        await store.startIfNeeded()
        try check(store.isPresentingCommit && store.selectedEntryIDs == [entry.id],
                  "reopening preserves the pending commit and file selection")
        try check(await service.loadCount == 1, "reopening does not reload the registration list")
        store.isPresentingCommit = false

        let nextCopy = service.copies[1]
        await store.selectWorkingCopyFromMenu(nextCopy.id)
        await store.startIfNeeded()
        try check(store.selectedWorkingCopyID == nextCopy.id, "reopening preserves menu navigation")
        try check(await service.statusRequests.count == 2, "reopening does not rescan the current working copy")
        await store.load()
        try check(await service.loadCount == 2, "explicit loading remains available after startup")
    }

    @MainActor
    private static func failedStartupCanRetry() async throws {
        let service = MenuBarStoreService(failsInitialLoad: true)
        let store = SvnDockStore(service: service)
        await store.startIfNeeded()
        try check(store.workingCopies.isEmpty && store.presentedError != nil,
                  "failed registry loading reports the initialization error")
        try check(await service.loadCount == 1, "a failed startup is attempted once per invocation")

        store.presentedError = nil
        await store.startIfNeeded()
        try check(await service.loadCount == 2, "reopening can retry failed registry initialization")
        try check(!store.workingCopies.isEmpty && !store.entries.isEmpty && store.presentedError == nil,
                  "retry publishes the registered copies and their status")

        let entry = try unwrap(store.entries.first)
        store.selectedEntryIDs = [entry.id]
        store.isPresentingCommit = true
        await store.startIfNeeded()
        try check(await service.loadCount == 2, "successful retry completes initialization permanently")
        try check(store.isPresentingCommit && store.selectedEntryIDs == [entry.id],
                  "reopening after recovery preserves the pending commit")
        store.isPresentingCommit = false
    }

    @MainActor
    private static func menuSelectionLoadsWithoutAnObserver() async throws {
        let service = MenuBarStoreService()
        let store = SvnDockStore(service: service)
        await store.load()
        let firstCopy = service.copies[0]
        let nextCopy = service.copies[1]
        await store.showHistory(for: firstCopy)
        store.selectedEntryIDs = [try unwrap(store.entries.first).id]
        await service.holdStatus(for: nextCopy.id)
        let selection = Task { await store.selectWorkingCopyFromMenu(nextCopy.id) }
        try await waitUntil { await service.statusRequests.count == 2 }
        try check(store.selectedWorkingCopyID == nextCopy.id && store.entries.isEmpty,
                  "menu navigation clears the previous status before scanning")
        try check(store.selectedEntryIDs.isEmpty && store.historyTarget == nil && store.historyEntries.isEmpty,
                  "menu navigation discards stale file and history selections")
        await store.selectedWorkingCopyDidChange(to: nextCopy.id)
        try check(await service.statusRequests.count == 2, "a newly opened window does not duplicate the menu scan")
        await service.finishStatus()
        await selection.value
        try check(store.entries.first?.workingCopyID == nextCopy.id,
                  "menu navigation publishes status without relying on a window observer")

        await store.selectWorkingCopyFromMenu(nextCopy.id)
        await store.selectWorkingCopyFromMenu(UUID())
        try check(store.selectedWorkingCopyID == nextCopy.id, "stale menu items cannot select an unregistered copy")
        try check(await service.statusRequests.count == 2, "opening the current copy does not trigger another scan")
        store.isPresentingCommit = true
        await store.selectWorkingCopyFromMenu(firstCopy.id)
        try check(store.selectedWorkingCopyID == nextCopy.id, "menu navigation respects an open commit presentation")
        store.isPresentingCommit = false
    }

    @MainActor
    private static func menuSelectionRejectsStaleResults() async throws {
        let service = MenuBarStoreService()
        let store = SvnDockStore(service: service)
        await store.load()
        let slowCopy = service.copies[1]
        let latestCopy = service.copies[2]
        await service.holdStatus(for: slowCopy.id)
        let firstSelection = Task { await store.selectWorkingCopyFromMenu(slowCopy.id) }
        try await waitUntil { await service.statusRequests.count == 2 }
        let latestSelection = Task { await store.selectWorkingCopyFromMenu(latestCopy.id) }
        try await waitUntil { store.selectedWorkingCopyID == latestCopy.id }
        await store.selectedWorkingCopyDidChange(to: slowCopy.id)
        try check(store.entries.isEmpty, "an obsolete window callback cannot restore stale status")
        await service.finishStatus()
        await firstSelection.value
        await latestSelection.value
        await store.selectedWorkingCopyDidChange(to: latestCopy.id)
        try check(await service.statusRequests.count == 3, "rapid navigation scans each target at most once")
        try check(await service.heldStatusWasCancelled, "leaving a copy cancels its pending status scan")
        try check(store.selectedWorkingCopyID == latestCopy.id
                  && store.entries.first?.workingCopyID == latestCopy.id,
                  "late results cannot replace the most recent menu selection")
        try check(store.presentedError == nil, "cancelled navigation does not present an error")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw MenuBarStoreFailure(message: message) }
    }

    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw MenuBarStoreFailure(message: "missing fixture") }
        return value
    }

    @MainActor
    private static func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard clock.now < deadline else {
                throw MenuBarStoreFailure(message: "timed out waiting for store operation")
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private actor MenuBarStoreService: SvnDockServicing {
    let copies = ["a", "b", "c"].map {
        SvnDockWorkingCopy(name: $0, rootURL: URL(fileURLWithPath: "/tmp/svndock-menu-fixture/\($0)"))
    }
    let holdsInitialLoad: Bool
    let failsInitialLoad: Bool
    var loadCount = 0
    var loadWasCancelled = false
    var statusRequests: [UUID] = []
    var heldStatusWasCancelled = false
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var heldStatusID: UUID?
    private var statusContinuation: CheckedContinuation<Void, Never>?

    init(holdsInitialLoad: Bool = false, failsInitialLoad: Bool = false) {
        self.holdsInitialLoad = holdsInitialLoad
        self.failsInitialLoad = failsInitialLoad
    }

    func loadRegisteredWorkingCopies() async throws -> [SvnDockWorkingCopy] {
        loadCount += 1
        if holdsInitialLoad, loadCount == 1 {
            await withCheckedContinuation { loadContinuation = $0 }
            loadWasCancelled = Task.isCancelled
            try Task.checkCancellation()
        }
        if failsInitialLoad, loadCount == 1 {
            throw MenuBarStoreFailure(message: "temporary registry read failure")
        }
        return copies
    }

    func finishInitialLoad() {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func holdStatus(for id: UUID) { heldStatusID = id }

    func finishStatus() {
        heldStatusID = nil
        statusContinuation?.resume()
        statusContinuation = nil
    }

    func status(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockStatusSnapshot {
        statusRequests.append(workingCopy.id)
        if heldStatusID == workingCopy.id {
            await withCheckedContinuation { statusContinuation = $0 }
            heldStatusWasCancelled = Task.isCancelled
            try Task.checkCancellation()
        }
        return SvnDockStatusSnapshot(entries: [
            .init(workingCopyID: workingCopy.id, relativePath: "\(workingCopy.name).txt",
                  nodeKind: .file, status: .modified)
        ])
    }

    func history(for workingCopy: SvnDockWorkingCopy, relativePaths: [String], limit: Int) async throws -> [SvnDockLogEntry] {
        [.init(revision: 1, author: "fixture", date: nil, message: "fixture history")]
    }
    func registerWorkingCopy(at url: URL) async throws -> SvnDockWorkingCopy { throw unsupported }
    func unregisterWorkingCopy(id: UUID) async throws { throw unsupported }
    func directoryChildren(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> [SvnDockStatusEntry] { throw unsupported }
    func diff(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> String { throw unsupported }
    func revisionDetails(revision: Int, in workingCopy: SvnDockWorkingCopy) async throws -> SVNRevisionDetails { throw unsupported }
    func revisionDiff(revision: Int, change: SVNChangedPath, repositoryRoot: URL, in workingCopy: SvnDockWorkingCopy) async throws -> String { throw unsupported }
    func update(workingCopies: [SvnDockWorkingCopy]) async throws { throw unsupported }
    func commit(workingCopy: SvnDockWorkingCopy, relativePaths: [String], message: String) async throws { throw unsupported }
    func add(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func unscheduleAdd(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func cleanupMissingAdditions(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func scheduleMissingDeletion(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func revert(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func resolve(relativePaths: [String], using resolution: SvnDockConflictResolution, in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func addIgnoreRules(_ rules: [SvnDockIgnoreRule], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func cleanup(workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    private var unsupported: MenuBarStoreFailure { MenuBarStoreFailure(message: "unexpected service call") }
}

private struct MenuBarStoreFailure: Error { let message: String }
