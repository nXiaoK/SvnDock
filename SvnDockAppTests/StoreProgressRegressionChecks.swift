import Combine
import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

@MainActor
enum StoreProgressRegressionChecks {
    static func run() async throws {
        try await commitReportsLiveProgressWithoutInvalidatingTheStore()
        try await updateProgressTracksEachCopyAndRejectsLateReports()
        try await unsuccessfulCommitClearsProgress()
    }

    static func commitReportsLiveProgressWithoutInvalidatingTheStore() async throws {
        let service = ProgressFixtureService()
        let store = makeStore(service: service)
        await store.load()
        guard let copy = store.selectedWorkingCopy, let entry = store.entries.first else { throw failure("missing commit fixture") }
        store.requestCommit()
        store.commit(message: "Commit progress fixture", entryIDs: [entry.id])
        try check(store.transferProgress.snapshot?.kind == .committing
                    && store.transferProgress.snapshot?.selectedItemCount == 1,
                  "commit publishes preparation and frozen selection immediately")
        try await waitUntil { await service.callbackCount == 1 }
        // Let initial store loading/preview tasks settle before measuring the
        // streamed updates independently of operation lifecycle notifications.
        try await Task.sleep(for: .milliseconds(200))
        var storeUpdates = 0
        var snapshots: [SvnDockTransferProgress] = []
        let storeSubscription = store.objectWillChange.sink { storeUpdates += 1 }
        let progressSubscription = store.transferProgress.$snapshot.sink { if let value = $0 { snapshots.append(value) } }
        defer { storeSubscription.cancel(); progressSubscription.cancel() }

        await service.report(.init(phase: .processing, processedItemCount: 3, currentPath: "src/数据库.java"), callback: 0)
        try await waitUntil { store.transferProgress.snapshot?.processedItems == 3 }
        try check(store.transferProgress.snapshot?.currentPath == "src/数据库.java"
                    && store.operationRecords.isEmpty && store.isBusy,
                  "file progress is visible before command completion without implying success")

        await service.report(.init(phase: .transferring, processedItemCount: 3), callback: 0)
        try await waitUntil { store.transferProgress.snapshot?.phase.contains("传输") == true }
        await service.report(.init(phase: .awaitingServer, processedItemCount: 3), callback: 0)
        try await waitUntil { store.transferProgress.snapshot?.phase.contains("仓库确认") == true }
        try check(store.operationRecords.isEmpty && store.isBusy, "server-wait notifications never complete a commit")

        let beforeFlood = snapshots.count
        await service.floodReports(count: 5_000, callback: 0)
        try await waitUntil { store.transferProgress.snapshot?.processedItems == 5_000 }
        try check(snapshots.count - beforeFlood < 50, "large output bursts are coalesced into bounded UI updates")
        await service.report(.init(phase: .processing, processedItemCount: 2, currentPath: "older.txt"), callback: 0)
        try await waitUntil { store.transferProgress.snapshot?.currentPath == "older.txt" }
        try check(store.transferProgress.snapshot?.processedItems == 5_000,
                  "cumulative progress never moves backward when receiving a stale count")
        try check(storeUpdates == 0,
                  "frequent progress notifications do not invalidate the entire store and its large commit list")
        try check(zip(snapshots, snapshots.dropFirst()).allSatisfy { $0.processedItems <= $1.processedItems },
                  "all published commit counts are monotonic")

        await service.releaseMutation(.success)
        try await waitUntil { await service.isVerifying(copy.id) }
        try check(store.transferProgress.snapshot?.phase.contains("刷新本地状态") == true,
                  "progress remains visible during post-commit status refresh")
        await service.report(.init(phase: .processing, processedItemCount: 99_999, currentPath: "late.txt"), callback: 0)
        try await Task.sleep(for: .milliseconds(150))
        try check(store.transferProgress.snapshot?.processedItems == 5_000
                    && store.transferProgress.snapshot?.phase.contains("刷新本地状态") == true,
                  "late command output cannot overwrite verification progress")
        await service.releaseVerification()
        try await waitUntil { store.transferProgress.snapshot == nil && !store.isBusy }
        try check(store.operationRecords.count == 1 && store.operationRecords[0].outcome == .success,
                  "completed commits clear the progress while keeping their confirmed result")
    }

    static func updateProgressTracksEachCopyAndRejectsLateReports() async throws {
        let service = ProgressFixtureService()
        let store = makeStore(service: service)
        await store.load()
        let copies = store.workingCopies
        let update = Task { await store.update(workingCopyIDs: Set(copies.map(\.id))) }
        try await waitUntil { await service.callbackCount == 1 }
        guard let initial = store.transferProgress.snapshot else { throw failure("missing update progress") }
        try check(initial.kind == .updating && initial.totalWorkingCopies == 2
                    && initial.completedWorkingCopies == 0 && initial.workingCopyName == copies[0].name,
                  "batch update starts with an accurate current copy and total copy count")
        await service.report(.init(phase: .processing, processedItemCount: 123, currentPath: "first.txt"), callback: 0)
        try await waitUntil { store.transferProgress.snapshot?.processedItems == 123 }
        await service.releaseMutation(.success)
        try await waitUntil { await service.isVerifying(copies[0].id) }
        try check(store.transferProgress.snapshot?.completedWorkingCopies == 0
                    && store.transferProgress.snapshot?.phase.contains("核验本地状态") == true,
                  "a copy stays in progress until its post-update status has been verified")
        await service.releaseVerification()
        try await waitUntil { await service.callbackCount == 2 }
        try check(store.transferProgress.snapshot?.workingCopyName == copies[1].name
                    && store.transferProgress.snapshot?.processedItems == 0
                    && store.transferProgress.snapshot?.currentPath == nil
                    && store.transferProgress.snapshot?.completedWorkingCopies == 1
                    && store.transferProgress.snapshot?.startedAt == initial.startedAt,
                  "the next copy resets path counts while preserving batch time and completed-copy count")
        await service.report(.init(phase: .processing, processedItemCount: 99_999, currentPath: "late-first.txt"), callback: 0)
        try await Task.sleep(for: .milliseconds(150))
        try check(store.transferProgress.snapshot?.processedItems == 0
                    && store.transferProgress.snapshot?.currentPath == nil,
                  "the previous copy's closed stream cannot leak output into the next copy")
        await service.report(.init(phase: .processing, processedItemCount: 17, currentPath: "second.txt"), callback: 1)
        try await waitUntil { store.transferProgress.snapshot?.processedItems == 17 }
        update.cancel()
        await service.releaseMutation(.success)
        try await waitUntil { await service.isVerifying(copies[1].id) }
        try check(store.transferProgress.snapshot?.phase.contains("核验本地状态") == true,
                  "cancellation retains progress through independent verification")
        await service.releaseVerification()
        let succeeded = await update.value
        try check(!succeeded && store.transferProgress.snapshot == nil && !store.isBusy,
                  "cancelled update clears progress and cannot claim success")
        try check(store.operationRecords.count == 2
                    && store.operationRecords.first?.outcome == .uncertain
                    && store.operationRecords.last?.outcome == .success,
                  "batch cancellation preserves the earlier confirmed result and the interrupted result")

        let obsoleteID = initial.operationID
        let replacementID = store.beginTransferProgress(kind: .updating, workingCopy: copies[0])
        store.setTransferProgressPhase("obsolete", id: obsoleteID)
        store.endTransferProgress(id: obsoleteID)
        try check(store.transferProgress.snapshot?.operationID == replacementID
                    && store.transferProgress.snapshot?.phase != "obsolete",
                  "obsolete operation cleanup never overwrites a newer progress session")
        store.endTransferProgress(id: replacementID)
    }

    static func unsuccessfulCommitClearsProgress() async throws {
        for result in [ProgressFixtureService.MutationResult.failure, .cancelled] {
            let service = ProgressFixtureService()
            let store = makeStore(service: service)
            await store.load()
            guard let entry = store.entries.first else { throw failure("missing failed commit fixture") }
            store.requestCommit()
            store.commit(message: "Uncertain commit", entryIDs: [entry.id])
            try await waitUntil { await service.callbackCount == 1 }
            await service.report(.init(phase: .awaitingServer, processedItemCount: 1), callback: 0)
            try await waitUntil { store.transferProgress.snapshot?.phase.contains("仓库确认") == true }
            await service.releaseMutation(result)
            try await waitUntil { store.transferProgress.snapshot == nil && !store.isBusy }
            try check(store.operationRecords.count == 1 && store.operationRecords[0].outcome == .uncertain,
                      "failed or cancelled commands clear progress without manufacturing successful completion")
            await service.report(.init(phase: .processing, processedItemCount: 99, currentPath: "late.txt"), callback: 0)
            try await Task.sleep(for: .milliseconds(120))
            try check(store.transferProgress.snapshot == nil, "late output cannot resurrect finished progress")
        }
    }

    private static func makeStore(service: ProgressFixtureService) -> SvnDockStore {
        SvnDockStore(service: service, commitDraftStore: SvnDockCommitDraftStore(defaults: ProgressMemoryDefaults()))
    }

    private static func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard clock.now < deadline else { throw failure("progress fixture timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw failure(message) }
    }

    private static func failure(_ message: String) -> ProgressCheckFailure { .init(message: message) }
}

private struct ProgressCheckFailure: Error { let message: String }

private final class ProgressMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    override func data(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }; return values[key]
    }
    override func set(_ value: Any?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }; values[key] = value as? Data
    }
    override func removeObject(forKey key: String) {
        lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: key)
    }
}

private actor ProgressFixtureService: SvnDockServicing {
    enum MutationResult: Sendable { case success, failure, cancelled }
    private let copies = (1...2).map {
        SvnDockWorkingCopy(name: "progress-\($0)", rootURL: URL(fileURLWithPath: "/tmp/svndock-progress-fixture-\($0)"))
    }
    private var callbacks: [@Sendable (SVNProgressSnapshot) -> Void] = []
    private var mutationContinuation: CheckedContinuation<MutationResult, Never>?
    private var verificationContinuation: CheckedContinuation<Void, Never>?
    private var awaitingVerification: UUID?
    private var verifyingCopyID: UUID?
    var callbackCount: Int { callbacks.count }

    func isVerifying(_ id: UUID) -> Bool { verifyingCopyID == id && verificationContinuation != nil }
    func report(_ snapshot: SVNProgressSnapshot, callback: Int) { callbacks[callback](snapshot) }
    func floodReports(count: Int, callback: Int) {
        for index in 1...count { callbacks[callback](.init(phase: .processing, processedItemCount: index, currentPath: "file-\(index).txt")) }
    }
    func releaseMutation(_ result: MutationResult) {
        mutationContinuation?.resume(returning: result)
        mutationContinuation = nil
    }
    func releaseVerification() {
        verificationContinuation?.resume()
        verificationContinuation = nil
        verifyingCopyID = nil
    }
    func loadRegisteredWorkingCopies() async throws -> [SvnDockWorkingCopy] { copies }
    func status(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockStatusSnapshot {
        if awaitingVerification == workingCopy.id {
            awaitingVerification = nil
            verifyingCopyID = workingCopy.id
            await withCheckedContinuation { verificationContinuation = $0 }
        }
        return .init(entries: [.init(workingCopyID: workingCopy.id, relativePath: "file.txt", nodeKind: .file, status: .modified)])
    }
    func update(workingCopies: [SvnDockWorkingCopy], progress: @escaping @Sendable (SVNProgressSnapshot) -> Void) async throws {
        try await mutation(copy: workingCopies[0], progress: progress)
    }
    func commit(workingCopy: SvnDockWorkingCopy, relativePaths: [String], message: String, progress: @escaping @Sendable (SVNProgressSnapshot) -> Void) async throws {
        try await mutation(copy: workingCopy, progress: progress)
    }
    private func mutation(copy: SvnDockWorkingCopy, progress: @escaping @Sendable (SVNProgressSnapshot) -> Void) async throws {
        callbacks.append(progress)
        let result = await withCheckedContinuation { mutationContinuation = $0 }
        switch result {
        case .success: awaitingVerification = copy.id
        case .failure: throw unsupported
        case .cancelled: throw CancellationError()
        }
    }

    func update(workingCopies: [SvnDockWorkingCopy]) async throws { throw unsupported }
    func commit(workingCopy: SvnDockWorkingCopy, relativePaths: [String], message: String) async throws { throw unsupported }
    func registerWorkingCopy(at url: URL) async throws -> SvnDockWorkingCopy { throw unsupported }
    func unregisterWorkingCopy(id: UUID) async throws { throw unsupported }
    func directoryChildren(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> [SvnDockStatusEntry] { throw unsupported }
    func diff(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> String { throw unsupported }
    func history(for workingCopy: SvnDockWorkingCopy, relativePaths: [String], limit: Int) async throws -> [SvnDockLogEntry] { throw unsupported }
    func revisionDetails(revision: Int, in workingCopy: SvnDockWorkingCopy) async throws -> SVNRevisionDetails { throw unsupported }
    func revisionDiff(revision: Int, change: SVNChangedPath, repositoryRoot: URL, in workingCopy: SvnDockWorkingCopy) async throws -> String { throw unsupported }
    func add(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func unscheduleAdd(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func cleanupMissingAdditions(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func scheduleMissingDeletion(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func revert(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func resolve(relativePaths: [String], using resolution: SvnDockConflictResolution, in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func addIgnoreRules(_ rules: [SvnDockIgnoreRule], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func cleanup(workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    private var unsupported: ProgressCheckFailure { .init(message: "unexpected progress fixture operation") }
}
