import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

@MainActor
enum ConflictReviewRegressionChecks {
    static func run() async throws {
        try await selectionAndConsent()
        try await frozenReviewAndPreview()
        try await operationOutcomes()
    }

    static func selectionAndConsent() async throws {
        let service = ConflictReviewFixtureService()
        let store = SvnDockStore(service: service)
        await store.load()
        let entries = store.entries
        guard let text = entries.first(where: { $0.relativePath == "text.txt" }),
              let property = entries.first(where: { $0.relativePath == "folder" }),
              let modified = entries.first(where: { $0.relativePath == "other.txt" }) else { throw Failure("missing fixtures") }
        let selection: Set<String> = [text.id, property.id, modified.id]
        store.selectedEntryIDs = selection
        store.requestResolveConfirmation(for: text, preserveSelection: true)
        guard let mixed = store.pendingConflictReview else { throw Failure("missing mixed review") }
        try check(mixed.relativePaths == ["folder", "text.txt"] && mixed.excludedSelectionCount == 1,
                  "a context review preserves the selected conflict subset and explains exclusions")
        try check(!mixed.allowsFileReplacement && store.selectedEntryIDs == selection,
                  "mixed conflict types cannot receive whole-file replacement and selection is unchanged")
        store.confirmResolve(using: .working, reviewID: mixed.id)
        store.confirmResolve(using: .mineFull, reviewed: true, reviewID: mixed.id)
        await Task.yield()
        try check(await service.resolveCalls.isEmpty && store.isPresentingResolveConfirmation,
                  "unreviewed and disallowed strategies leave the review open without mutation")
        store.cancelResolveConfirmation()
        try check(store.pendingConflictReview == nil && store.operationRecords.isEmpty,
                  "closing a review never creates a resolve result")

        store.requestResolveConfirmation(for: text)
        guard let single = store.pendingConflictReview else { throw Failure("missing single review") }
        try check(single.relativePaths == ["text.txt"] && single.allowsFileReplacement,
                  "an explicit single-item action does not silently expand to other selected conflicts")
        store.cancelResolveConfirmation()
        store.requestResolveConfirmation(for: text)
        guard let current = store.pendingConflictReview else { throw Failure("missing new review") }
        store.confirmResolve(using: .working, reviewed: true, reviewID: single.id)
        let callsAfterOldConsent = await service.resolveCalls
        try check(current.id != single.id && store.pendingConflictReview?.id == current.id
                  && !store.isBusy && callsAfterOldConsent.isEmpty,
                  "consent from a dismissed sheet cannot execute a newly opened review")
        store.cancelResolveConfirmation()
        store.searchQuery = "not-a-match"
        store.requestResolveAllConflicts()
        try check(store.pendingConflictReview?.entries.count == 3
                  && store.pendingConflictReview?.excludedSelectionCount == 0,
                  "the explicit all-conflicts action includes every conflict despite search and selection")
        store.cancelResolveConfirmation()
        store.showConflicts()
        try check(store.searchQuery.isEmpty && store.statusFilter == .conflicts
                  && store.selectedEntries.first?.status == .conflicted && store.inspectorTab == .diff,
                  "show conflicts clears hidden filters and selects an actionable conflict")
    }

    static func frozenReviewAndPreview() async throws {
        let service = ConflictReviewFixtureService()
        let store = SvnDockStore(service: service)
        await store.load()
        guard let text = store.entries.first(where: { $0.relativePath == "text.txt" }),
              let other = store.entries.first(where: { $0.relativePath == "other.txt" }) else { throw Failure("missing fixtures") }
        store.selectedEntryIDs = [text.id]
        store.requestResolveConfirmation()
        guard let review = store.pendingConflictReview else { throw Failure("missing review") }
        store.selectedEntryIDs = [other.id]
        let preview = try await store.conflictDiff(for: text, in: review)
        try check(preview.contains("fixture diff") && store.selectedEntryIDs == [other.id] && store.diffText.isEmpty,
                  "review preview uses its frozen path without replacing the main inspector selection or diff")
        store.confirmResolve(using: .mineFull, reviewed: true, reviewID: review.id)
        try await waitUntil { !store.isBusy && store.operationRecords.count == 1 }
        let calls = await service.resolveCalls
        try check(calls.count == 1 && calls[0].paths == ["text.txt"]
                  && calls[0].workingCopyID == review.workingCopy.id && calls[0].resolution == .mineFull,
                  "confirmation executes its frozen working-copy and path exactly once")
        do {
            _ = try await store.conflictDiff(for: text, in: review)
            throw Failure("dismissed review preview should be rejected")
        } catch SvnDockServiceError.unavailable { }
        let symlink = SvnDockStatusEntry(workingCopyID: review.workingCopy.id, relativePath: "link",
                                        nodeKind: .file, isSymbolicLink: true, status: .conflicted)
        let linkReview = SvnDockConflictReview(workingCopy: review.workingCopy, entries: [symlink], excludedSelectionCount: 0)
        try check(!linkReview.allowsFileReplacement, "symbolic links are not offered whole-file replacement")
    }

    static func operationOutcomes() async throws {
        for outcome in ConflictReviewFixtureService.Result.allCases {
            let service = ConflictReviewFixtureService(result: outcome)
            let store = SvnDockStore(service: service)
            await store.load()
            guard let text = store.entries.first(where: { $0.relativePath == "text.txt" }) else { throw Failure("missing text") }
            store.requestResolveConfirmation(for: text)
            guard let review = store.pendingConflictReview else { throw Failure("missing review") }
            store.confirmResolve(using: .working, reviewed: true, reviewID: review.id)
            try await waitUntil {
                let statusCalls = await service.statusCalls
                return !store.isBusy && store.operationRecords.count == 1 && statusCalls >= 2
            }
            let record = store.operationRecords[0]
            let expected: SvnDockOperationRecord.Outcome = switch outcome {
            case .success: .success
            case .remaining: .failure
            case .statusUnavailable, .commandFailure, .cancelled: .uncertain
            }
            try check(record.outcome == expected && record.actionTitle == "解决冲突"
                      && record.workingCopyID == review.workingCopy.id && record.detail?.contains("text.txt") == true,
                      "resolve record preserves identity, scope and verified outcome for \(outcome)")
            if expected == .success {
                try check(record.summary.contains("仍需提交"), "clearing conflicts is not presented as committing changes")
            }
            if expected == .uncertain {
                try check(record.detail?.contains("未自动重试") == true,
                          "uncertain outcomes explain that files or markers may have changed without retrying")
            }
            // Cancellation thrown by the fixture does not cancel the caller;
            // all these paths should refresh behind any error alert.
            try check(await service.statusCalls >= 2, "completed attempts refresh local status even when an error alert is shown")
            for _ in 0..<10 { await Task.yield() }
            try check(await service.resolveCalls.count == 1, "resolve never automatically retries a strategy")
        }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }
    private static func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard clock.now < deadline else { throw Failure("conflict review fixture timed out") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}

private actor ConflictReviewFixtureService: SvnDockServicing {
    enum Result: CaseIterable, Sendable { case success, remaining, statusUnavailable, commandFailure, cancelled }
    struct Call: Sendable { let workingCopyID: UUID; let paths: [String]; let resolution: SvnDockConflictResolution }
    let copy = SvnDockWorkingCopy(name: "Conflict fixture", rootURL: URL(fileURLWithPath: "/tmp/conflict-review-fixture"))
    let result: Result
    var resolveCalls: [Call] = []
    var statusCalls = 0
    var resolvedPaths: Set<String> = []
    init(result: Result = .success) { self.result = result }
    func loadRegisteredWorkingCopies() async throws -> [SvnDockWorkingCopy] { [copy] }
    func status(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockStatusSnapshot {
        statusCalls += 1
        return .init(entries: [
            .init(workingCopyID: copy.id, relativePath: "text.txt", nodeKind: .file, status: .conflicted, conflictKinds: [.text]),
            .init(workingCopyID: copy.id, relativePath: "folder", nodeKind: .directory, status: .conflicted, conflictKinds: [.property]),
            .init(workingCopyID: copy.id, relativePath: "tree", nodeKind: .directory, status: .conflicted, conflictKinds: [.tree]),
            .init(workingCopyID: copy.id, relativePath: "other.txt", nodeKind: .file, status: .modified)
        ].filter { !resolvedPaths.contains($0.relativePath) })
    }
    func diff(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> String { "fixture diff for \(relativePath)" }
    func resolve(relativePaths: [String], using resolution: SvnDockConflictResolution, in workingCopy: SvnDockWorkingCopy) async throws {
        resolveCalls.append(.init(workingCopyID: workingCopy.id, paths: relativePaths, resolution: resolution))
        switch result {
        case .success: resolvedPaths.formUnion(relativePaths)
        case .remaining: throw SvnDockResolveVerificationError.remainingConflicts(paths: relativePaths)
        case .statusUnavailable: throw SvnDockResolveVerificationError.statusUnavailable(detail: "fixture status failed")
        case .commandFailure: throw unavailable
        case .cancelled: throw CancellationError()
        }
    }
    func registerWorkingCopy(at url: URL) async throws -> SvnDockWorkingCopy { throw unavailable }
    func unregisterWorkingCopy(id: UUID) async throws { throw unavailable }
    func directoryChildren(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> [SvnDockStatusEntry] { throw unavailable }
    func history(for workingCopy: SvnDockWorkingCopy, relativePaths: [String], limit: Int) async throws -> [SvnDockLogEntry] { throw unavailable }
    func revisionDetails(revision: Int, in workingCopy: SvnDockWorkingCopy) async throws -> SVNRevisionDetails { throw unavailable }
    func revisionDiff(revision: Int, change: SVNChangedPath, repositoryRoot: URL, in workingCopy: SvnDockWorkingCopy) async throws -> String { throw unavailable }
    func update(workingCopies: [SvnDockWorkingCopy]) async throws { throw unavailable }
    func commit(workingCopy: SvnDockWorkingCopy, relativePaths: [String], message: String) async throws { throw unavailable }
    func add(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func unscheduleAdd(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func cleanupMissingAdditions(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func scheduleMissingDeletion(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func revert(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func addIgnoreRules(_ rules: [SvnDockIgnoreRule], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func cleanup(workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    private var unavailable: SvnDockServiceError { .unavailable("fixture failure") }
}
