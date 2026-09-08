import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

@MainActor
enum OperationStoreRegressionChecks {
    static func run() async throws {
        try await updateAllRetainsIndividualResults()
        try await updateAllRefreshesEveryAttemptedCopy()
        try await cancelledUpdateStopsRemainingCopies()
        try await commitOutcomesReflectExecutionCertainty()
    }

    static func updateAllRetainsIndividualResults() async throws {
        let service = OperationResultFixtureService(updateMode: .failSecond)
        let store = makeStore(service: service)
        await store.load()
        let copies = store.workingCopies
        try check(copies.count == 3, "update fixture loads three working copies")

        let succeeded = await store.update(workingCopyIDs: Set(copies.map(\.id)))
        try check(!succeeded, "one failed copy makes the overall update report failure")
        let calls = await service.updateCalls
        try check(calls == copies.map { [$0.id] },
                  "each selected copy is attempted once, and a failure does not skip the later copy")
        let records = store.operationRecords
        try check(records.count == 3, "each attempted update produces exactly one operation record")
        for (index, copy) in copies.enumerated() {
            let matching = records.filter { $0.workingCopyID == copy.id }
            try check(matching.count == 1, "each update result retains its exact working-copy identity")
            let record = matching[0]
            try check(record.workingCopyName == copy.name && record.actionTitle == "更新",
                      "update records show the corresponding copy name and action")
            try check(record.outcome == (index == 1 ? .failure : .success),
                      "individual update outcomes distinguish success from failure")
            try check(record.finishedAt >= record.startedAt, "operation timestamps describe a completed interval")
        }
        try check(records.map(\.workingCopyID) == copies.reversed().map(\.id),
                  "the newest completed operation is displayed first")
        for _ in 0..<10 { await Task.yield() }
        let finalCalls = await service.updateCalls
        try check(finalCalls == calls && store.operationRecords.count == 3,
                  "failed updates are not automatically retried or recorded twice")
    }

    static func cancelledUpdateStopsRemainingCopies() async throws {
        let service = OperationResultFixtureService(updateMode: .holdSecond)
        let store = makeStore(service: service)
        await store.load()
        let copies = store.workingCopies
        let operation = Task { await store.update(workingCopyIDs: Set(copies.map(\.id))) }
        try await waitUntil { await service.isHoldingUpdate }
        operation.cancel()
        await service.releaseHeldUpdate()
        let succeeded = await operation.value
        try check(!succeeded, "cancelled updates cannot report overall success")
        let calls = await service.updateCalls
        try check(calls == copies.prefix(2).map { [$0.id] },
                  "cancelling the active update leaves subsequent copies unexecuted")
        let records = store.operationRecords
        try check(records.count == 2 && records.first?.workingCopyID == copies[1].id,
                  "unexecuted copies receive no misleading completion record")
        try check(records.first?.outcome == .uncertain && records.last?.outcome == .success,
                  "cancellation after the service returns preserves prior success and marks the active result uncertain")
        try check(!store.isBusy, "cancellation releases the store's operation state")
        let verificationCalls = await service.statusCalls
        try check(Array(verificationCalls.suffix(2)) == copies.prefix(2).map(\.id),
                  "cancellation still verifies every attempted copy, including the interrupted one")
        try check(await service.cancelledStatusReads == 0,
                  "update cancellation does not cancel the independent status verification")
        for _ in 0..<10 { await Task.yield() }
        let finalCalls = await service.updateCalls
        try check(finalCalls == calls, "cancelled operations do not restart in the background")
    }

    static func updateAllRefreshesEveryAttemptedCopy() async throws {
        for mode in [OperationResultFixtureService.UpdateMode.succeed, .failSecond, .failVerificationSecond] {
            let service = OperationResultFixtureService(updateMode: mode)
            let store = makeStore(service: service)
            await store.load()
            let copies = store.workingCopies
            // Seed every sidebar summary, then update while viewing only the first copy.
            for copy in copies.dropFirst() { await store.selectWorkingCopyFromMenu(copy.id) }
            await store.selectWorkingCopyFromMenu(copies[0].id)
            let previousCalls = await service.statusCalls.count
            let succeeded = await store.update(workingCopyIDs: Set(copies.map(\.id)))
            try check(succeeded == (mode == .succeed), "batch result reflects mutation and verification failures")
            let verificationCalls = await service.statusCalls
            try check(Array(verificationCalls.dropFirst(previousCalls)) == copies.map(\.id),
                      "every attempted copy receives one status scan, with no extra selected-copy scan")
            try check(store.selectedWorkingCopyID == copies[0].id && store.hasLoadedStatus
                        && store.statusCounts.conflicts == 1 && store.statusRecoveryMessage == nil,
                      "other copies never replace the selected snapshot or its recovery message")
            for (index, original) in copies.enumerated() {
                guard let refreshed = store.workingCopies.first(where: { $0.id == original.id }),
                      let record = store.operationRecords.first(where: { $0.workingCopyID == original.id }) else {
                    throw OperationStoreCheckFailure(message: "missing refreshed batch summary")
                }
                if mode == .failVerificationSecond && index == 1 {
                    try check(refreshed.lastRefreshedAt == nil && refreshed.counts == .zero,
                              "unverified nonselected copy is visibly unknown rather than falsely clean")
                    try check(record.outcome == .uncertain && record.detail?.contains("状态") == true,
                              "a successful command with failed verification remains uncertain")
                } else {
                    try check(refreshed.lastRefreshedAt != nil && refreshed.counts.conflicts == 1
                                && refreshed.revision == 99,
                              "each sidebar summary publishes new conflicts and metadata even after a failed command")
                    if mode == .succeed {
                        try check(record.summary.contains("1 项冲突"), "successful updates report discovered conflicts")
                    }
                }
            }
            try check(await service.updateCalls.count == copies.count, "verification never repeats an update")
        }
    }

    static func commitOutcomesReflectExecutionCertainty() async throws {
        for result in OperationResultFixtureService.CommitResult.allCases {
            let service = OperationResultFixtureService(commitResult: result)
            let store = makeStore(service: service)
            await store.load()
            guard let copy = store.selectedWorkingCopy, let entry = store.entries.first else {
                throw OperationStoreCheckFailure(message: "missing commit fixture")
            }
            let drafts = store.commitDraftStore
            let draft = SvnDockCommitDraft(
                message: "Fixture change\n\nPreserve the review context.",
                includedRelativePaths: [entry.relativePath],
                previewRelativePath: entry.relativePath
            )
            try drafts.save(draft, for: copy)
            guard let unrelatedCopy = store.workingCopies.first(where: { $0.id != copy.id }) else {
                throw OperationStoreCheckFailure(message: "missing unrelated working-copy fixture")
            }
            let unrelatedDraft = SvnDockCommitDraft(
                message: "Another task", includedRelativePaths: ["other.txt"], previewRelativePath: "other.txt"
            )
            try drafts.save(unrelatedDraft, for: unrelatedCopy)
            store.requestCommit()
            store.commit(message: draft.message, entryIDs: [entry.id])
            try await waitUntil { !store.isBusy && store.operationRecords.count == 1 }
            let record = store.operationRecords[0]
            try check(record.workingCopyID == copy.id && record.workingCopyName == copy.name
                      && record.actionTitle == "提交", "commit result is attributed to its frozen working copy")
            let expected: SvnDockOperationRecord.Outcome
            switch result {
            case .preflightMissingParent: expected = .failure
            case .success: expected = .success
            case .commandFailure, .genericFailure, .cancelled, .successThenCancelled: expected = .uncertain
            }
            try check(record.outcome == expected, "commit certainty is correct for \(result)")
            try check(record.finishedAt >= record.startedAt, "commit completion timestamps remain ordered")
            if expected == .uncertain {
                try check(record.detail?.contains("历史") == true && record.detail?.contains("重试") == true,
                          "uncertain commits direct users to verify history before retrying")
            }
            for _ in 0..<10 { await Task.yield() }
            let calls = await service.commitCalls
            try check(calls == [[entry.relativePath]] && store.operationRecords.count == 1,
                      "commit failure or cancellation does not trigger an automatic retry")
            let retainedDraft = try drafts.draft(for: copy)
            if expected == .success {
                try check(retainedDraft == nil, "only a confirmed successful commit clears its saved draft")
            } else {
                try check(retainedDraft == draft,
                          "preflight failure and uncertain execution preserve the exact message, selection and preview for \(result)")
            }
            try check(try drafts.draft(for: unrelatedCopy) == unrelatedDraft,
                      "every commit outcome preserves drafts belonging to other working copies")
        }
    }

    private static func makeStore(service: OperationResultFixtureService) -> SvnDockStore {
        // This fake only replaces the storage backend. All scheduling, record
        // creation and outcome classification exercise the production store.
        let defaults = OperationResultMemoryDefaults()
        return SvnDockStore(service: service, commitDraftStore: SvnDockCommitDraftStore(defaults: defaults))
    }

    private static func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard clock.now < deadline else { throw OperationStoreCheckFailure(message: "operation fixture timed out") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw OperationStoreCheckFailure(message: message) }
    }
}

/// Operation tests never read or alter the user's actual draft preferences.
private final class OperationResultMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    override func data(forKey defaultName: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.lock()
        defer { lock.unlock() }
        values[defaultName] = value as? Data
    }

    override func removeObject(forKey defaultName: String) {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: defaultName)
    }
}

private struct OperationStoreCheckFailure: Error { let message: String }

private actor OperationResultFixtureService: SvnDockServicing {
    enum UpdateMode: Sendable { case succeed, failSecond, holdSecond, failVerificationSecond }
    enum CommitResult: CaseIterable, Sendable {
        case preflightMissingParent, commandFailure, genericFailure, cancelled, successThenCancelled, success
    }

    let copies: [SvnDockWorkingCopy] = (1...3).map {
        SvnDockWorkingCopy(name: "fixture-\($0)", rootURL: URL(fileURLWithPath: "/tmp/svndock-operation-fixture-\($0)"))
    }
    let updateMode: UpdateMode
    let commitResult: CommitResult
    var updateCalls: [[UUID]] = []
    private(set) var statusCalls: [UUID] = []
    private(set) var cancelledStatusReads = 0
    var commitCalls: [[String]] = []
    private var updateContinuation: CheckedContinuation<Void, Never>?
    var isHoldingUpdate: Bool { updateContinuation != nil }

    init(updateMode: UpdateMode = .succeed, commitResult: CommitResult = .success) {
        self.updateMode = updateMode
        self.commitResult = commitResult
    }

    func loadRegisteredWorkingCopies() async throws -> [SvnDockWorkingCopy] { copies }
    func status(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockStatusSnapshot {
        statusCalls.append(workingCopy.id)
        if Task.isCancelled { cancelledStatusReads += 1 }
        let updated = updateCalls.contains { $0.contains(workingCopy.id) }
        if updateMode == .failVerificationSecond, workingCopy.id == copies[1].id, updated { throw unsupported }
        return SvnDockStatusSnapshot(entries: [
            .init(workingCopyID: workingCopy.id, relativePath: "file.txt", nodeKind: .file, status: updated ? .conflicted : .modified)
        ])
    }
    func refreshWorkingCopyMetadata(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockWorkingCopy {
        var copy = workingCopy
        if updateCalls.contains(where: { $0.contains(copy.id) }) { copy.revision = 99 }
        return copy
    }
    func update(workingCopies: [SvnDockWorkingCopy]) async throws {
        updateCalls.append(workingCopies.map(\.id))
        guard updateCalls.count == 2 else { return }
        switch updateMode {
        case .succeed, .failVerificationSecond: break
        case .failSecond: throw unsupported
        case .holdSecond: await withCheckedContinuation { updateContinuation = $0 }
        }
    }
    func releaseHeldUpdate() {
        updateContinuation?.resume()
        updateContinuation = nil
    }
    func commit(workingCopy: SvnDockWorkingCopy, relativePaths: [String], message: String) async throws {
        commitCalls.append(relativePaths)
        switch commitResult {
        case .preflightMissingParent: throw SVNSelectedCommitError.missingParent("new-folder")
        case .commandFailure: throw SVNSelectedCommitError.commandFailed("fixture server connection failed")
        case .genericFailure: throw unsupported
        case .cancelled: throw CancellationError()
        case .successThenCancelled: withUnsafeCurrentTask { $0?.cancel() }
        case .success: break
        }
    }

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
    private var unsupported: OperationStoreCheckFailure { .init(message: "fixture service failure") }
}
