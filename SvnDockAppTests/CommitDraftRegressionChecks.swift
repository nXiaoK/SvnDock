import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

@MainActor
enum CommitDraftRegressionChecks {
    static func run() async throws {
        let suiteName = "svndock-commit-drafts-\(UUID())"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw DraftCheckFailure(message: "could not create isolated draft storage")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let drafts = SvnDockCommitDraftStore(defaults: defaults)
        let copy = SvnDockWorkingCopy(name: "fixture", rootURL: URL(fileURLWithPath: "/tmp/draft-fixture"))
        let first = SvnDockStatusEntry(workingCopyID: copy.id, relativePath: "src/登录.swift",
                                      nodeKind: .file, status: .modified)
        let newEntry = SvnDockStatusEntry(workingCopyID: copy.id, relativePath: "debug.txt",
                                         nodeKind: .file, status: .added)
        let draft = SvnDockCommitDraft(message: "修复登录\n\nPreserve Unicode and paragraphs.",
                                      includedRelativePaths: [first.relativePath, "no-longer-modified"],
                                      previewRelativePath: first.relativePath)
        try check(try drafts.draft(for: copy) == nil, "new copies have no saved draft")
        try drafts.save(draft, for: copy)
        let restoredStore = SvnDockCommitDraftStore(defaults: defaults)
        let restoredDraft = try restoredStore.draft(for: copy)
        try check(restoredDraft == draft, "message, inclusion and preview survive storage recreation")
        try check(SvnDockCommitDraft.initialIncludedEntryIDs(
            entries: [first, newEntry], selectedEntryIDs: [newEntry.id], savedDraft: restoredDraft
        ) == [first.id], "saved scope wins over later selection, drops stale paths and excludes new changes")

        var otherRoot = copy
        otherRoot.rootURL = URL(fileURLWithPath: "/tmp/other-draft-fixture")
        try check(try restoredStore.draft(for: otherRoot) == nil, "the same ID at a different root is isolated")
        let otherID = SvnDockWorkingCopy(name: copy.name, rootURL: copy.rootURL)
        try check(try restoredStore.draft(for: otherID) == nil, "a new registration at the same root is isolated")
        var equivalentRoot = copy
        equivalentRoot.rootURL = copy.rootURL.appendingPathComponent(".")
        try check(try restoredStore.draft(for: equivalentRoot) == draft, "equivalent standardized roots share the draft")
        try drafts.save(draft, for: otherRoot)
        drafts.remove(for: copy)
        try check(try drafts.draft(for: copy) == nil, "confirmed removal deletes only the requested draft")
        try check(try drafts.draft(for: otherRoot) == draft, "removal preserves the other working copy")

        let empty = SvnDockCommitDraft(message: "", includedRelativePaths: [], previewRelativePath: nil)
        try drafts.save(empty, for: copy)
        try check(SvnDockCommitDraft.initialIncludedEntryIDs(
            entries: [first, newEntry], selectedEntryIDs: [], savedDraft: try drafts.draft(for: copy)
        ).isEmpty, "clearing a draft preserves an explicit empty selection on reopening")
        try check(SvnDockCommitDraft.initialIncludedEntryIDs(
            entries: [first, newEntry], selectedEntryIDs: [], savedDraft: nil
        ) == [first.id, newEntry.id], "first opening without a selection retains the existing select-all behavior")
        try check(SvnDockCommitDraft.initialIncludedEntryIDs(
            entries: [first, newEntry], selectedEntryIDs: [first.id, "uncommittable"], savedDraft: nil
        ) == [first.id], "first opening honors an explicit committable selection")

        for result in DraftCommitService.Result.allCases {
            try await checkCommitLifecycle(result: result, drafts: drafts)
        }
    }

    private static func checkCommitLifecycle(
        result: DraftCommitService.Result,
        drafts: SvnDockCommitDraftStore
    ) async throws {
        let service = DraftCommitService(result: result)
        let store = SvnDockStore(service: service, commitDraftStore: drafts)
        await store.load()
        guard let copy = store.selectedWorkingCopy, let entry = store.entries.first else {
            throw DraftCheckFailure(message: "missing commit fixture")
        }
        let draft = SvnDockCommitDraft(message: "A recoverable draft", includedRelativePaths: [entry.relativePath],
                                      previewRelativePath: entry.relativePath)
        try drafts.save(draft, for: copy)
        store.requestCommit()
        store.cancelCommit()
        try check(try drafts.draft(for: copy) == draft, "closing the sheet preserves its saved draft")
        store.requestCommit()
        store.commit(message: draft.message, entryIDs: [entry.id])
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while store.isBusy {
            guard clock.now < deadline else { throw DraftCheckFailure(message: "commit fixture timed out") }
            try await Task.sleep(for: .milliseconds(1))
        }
        // The store's commit task may still be unwinding after publishing idle.
        for _ in 0..<5 { await Task.yield() }
        let retained = try drafts.draft(for: copy)
        switch result {
        case .success, .successWithFailedRefresh:
            try check(retained == nil, "confirmed success clears draft even if the following refresh fails")
            try check(!store.isPresentingCommit, "confirmed success closes the commit sheet")
        case .failure, .cancelled, .successThenCancelled:
            try check(retained == draft, "failed and uncertain commit results preserve the complete draft")
        }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw DraftCheckFailure(message: message) }
    }
}

private struct DraftCheckFailure: Error { let message: String }

private actor DraftCommitService: SvnDockServicing {
    enum Result: CaseIterable, Sendable {
        case success, failure, cancelled, successThenCancelled, successWithFailedRefresh
    }
    private let result: Result
    private let copy = SvnDockWorkingCopy(name: "draft-test", rootURL: URL(fileURLWithPath: "/tmp/draft-commit-test"))
    private var didCommit = false

    init(result: Result) { self.result = result }

    func loadRegisteredWorkingCopies() async throws -> [SvnDockWorkingCopy] { [copy] }
    func status(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockStatusSnapshot {
        if didCommit, result == .successWithFailedRefresh { throw unsupported }
        return SvnDockStatusSnapshot(entries: didCommit ? [] : [
            .init(workingCopyID: copy.id, relativePath: "file.txt", nodeKind: .file, status: .modified)
        ])
    }
    func commit(workingCopy: SvnDockWorkingCopy, relativePaths: [String], message: String) async throws {
        switch result {
        case .failure: throw unsupported
        case .cancelled: throw CancellationError()
        case .successThenCancelled:
            didCommit = true
            withUnsafeCurrentTask { $0?.cancel() }
        case .success, .successWithFailedRefresh: didCommit = true
        }
    }

    func registerWorkingCopy(at url: URL) async throws -> SvnDockWorkingCopy { throw unsupported }
    func unregisterWorkingCopy(id: UUID) async throws { throw unsupported }
    func directoryChildren(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> [SvnDockStatusEntry] { throw unsupported }
    func diff(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> String { throw unsupported }
    func history(for workingCopy: SvnDockWorkingCopy, relativePaths: [String], limit: Int) async throws -> [SvnDockLogEntry] { throw unsupported }
    func revisionDetails(revision: Int, in workingCopy: SvnDockWorkingCopy) async throws -> SVNRevisionDetails { throw unsupported }
    func revisionDiff(revision: Int, change: SVNChangedPath, repositoryRoot: URL, in workingCopy: SvnDockWorkingCopy) async throws -> String { throw unsupported }
    func update(workingCopies: [SvnDockWorkingCopy]) async throws { throw unsupported }
    func add(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func unscheduleAdd(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func cleanupMissingAdditions(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func scheduleMissingDeletion(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func revert(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func resolve(relativePaths: [String], using resolution: SvnDockConflictResolution, in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func addIgnoreRules(_ rules: [SvnDockIgnoreRule], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func cleanup(workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    private var unsupported: DraftCheckFailure { DraftCheckFailure(message: "fixture failure") }
}
