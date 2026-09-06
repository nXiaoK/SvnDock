import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum HistoryPagingRegressionChecks {
    @MainActor
    static func run() async throws {
        try await pageBoundariesAndEmptyTail()
        try await sparseRevisionsAndNewHead()
        try await failedPageRetriesItsCursor()
        try await refreshRetainsThenReplacesHistory()
        try await changingTargetDiscardsLateResponse()
        try await hiddenHistoryCanResume()
        try await localRefreshInvalidatesPaging()
    }

    @MainActor
    static func pageBoundariesAndEmptyTail() async throws {
        for count in [0, 100, 101] {
            let fixture = try await makeFixture(revisions: count == 0 ? [] : Array((1...count).reversed()))
            await fixture.store.showHistory(for: fixture.first)
            try check(fixture.store.historyHasLoaded, "even an empty successful page is recorded as loaded")
            try check(fixture.store.historyEntries.count == min(count, 100),
                      "the first page exposes at most 100 entries rather than its probe")
            try check(fixture.store.historyHasMore == (count > 100),
                      "the extra probe alone determines whether another page exists")
            let requests = await fixture.service.requests
            try check(requests.count == 1 && requests[0].limit == 101 && requests[0].beforeRevision == nil,
                      "the initial query requests 100 entries plus one probe at HEAD")
            if count == 101 {
                let original = fixture.store.historyEntries
                // A path can disappear from an accessible history range after
                // the probe. An empty tail still terminates pagination safely.
                await fixture.service.replaceFirstHistory(with: original.map(\.revision))
                await fixture.store.loadMoreHistory()
                try check(fixture.store.historyEntries == original && !fixture.store.historyHasMore,
                          "an empty tail keeps earlier rows and disables further paging")
            } else {
                await fixture.store.loadMoreHistory()
                let callsAfterNoOp = await fixture.service.requests.count
                try check(callsAfterNoOp == 1, "a completed history does not request a redundant tail")
            }
        }
    }

    @MainActor
    static func sparseRevisionsAndNewHead() async throws {
        let revisions = (0..<1_101).map { 20_000 - $0 * 7 }
        let fixture = try await makeFixture(revisions: revisions)
        await fixture.store.showHistory(for: fixture.first)
        let firstPage = Array(revisions.prefix(100))
        try check(fixture.store.historyEntries.map(\.revision) == firstPage,
                  "sparse revision numbers do not change page cardinality")
        await fixture.service.replaceFirstHistory(with: [30_001, 30_000] + revisions)

        for page in 1...11 {
            let cursor = fixture.store.historyEntries.last?.revision
            await fixture.store.loadMoreHistory()
            let request = await fixture.service.requests.last
            try check(request?.beforeRevision == cursor && request?.limit == 101,
                      "page \(page) continues before the last displayed revision")
        }
        try check(fixture.store.historyEntries.map(\.revision) == revisions,
                  "new HEAD commits cannot duplicate or displace older pages, including records beyond 1,000")
        try check(!fixture.store.historyHasMore && !fixture.store.isLoadingMoreHistory,
                  "the final short page completes pagination")
        try check(Set(fixture.store.historyEntries.map(\.revision)).count == revisions.count,
                  "every loaded revision appears only once")

        let duplicates = try await makeFixture(revisions: Array((1...101).reversed()))
        await duplicates.store.showHistory(for: duplicates.first)
        await duplicates.service.overrideNextPage(with: [1, 1])
        await duplicates.store.loadMoreHistory()
        try check(duplicates.store.historyEntries.map(\.revision) == Array((1...101).reversed()),
                  "duplicate rows within a page are removed during append")
    }

    @MainActor
    static func failedPageRetriesItsCursor() async throws {
        let revisions = Array((1...201).reversed())
        let fixture = try await makeFixture(revisions: revisions)
        await fixture.store.showHistory(for: fixture.first)
        let original = fixture.store.historyEntries
        await fixture.service.failNextPage()
        await fixture.store.loadMoreHistory()
        try check(fixture.store.historyEntries == original && fixture.store.historyErrorMessage != nil,
                  "a failed tail request preserves all displayed history")
        try check(fixture.store.historyHasMore && !fixture.store.isLoadingMoreHistory && !fixture.store.historyIsStale,
                  "a failed page remains retryable after its loading state ends")
        await fixture.store.retryHistory()
        let requests = await fixture.service.requests
        try check(requests.count == 3
                    && requests[1].beforeRevision == original.last?.revision
                    && requests[2].beforeRevision == requests[1].beforeRevision,
                  "retry targets the same failed cursor instead of skipping a page or restarting at HEAD")
        try check(fixture.store.historyEntries.map(\.revision) == Array(revisions.prefix(200))
                    && fixture.store.historyErrorMessage == nil,
                  "a successful retry appends its page and clears the error")
        await fixture.store.loadMoreHistory()
        try check(fixture.store.historyEntries.map(\.revision) == revisions && !fixture.store.historyHasMore,
                  "paging after a retry still reaches the final revision")
    }

    @MainActor
    static func refreshRetainsThenReplacesHistory() async throws {
        let fixture = try await makeFixture(revisions: Array((1...201).reversed()))
        await fixture.store.showHistory(for: fixture.first)
        await fixture.store.loadMoreHistory()
        let original = fixture.store.historyEntries
        let originalTarget = fixture.store.historyTarget?.id
        await fixture.service.failNextPage()
        await fixture.store.refreshHistory()
        try check(fixture.store.historyEntries == original && fixture.store.historyTarget?.id == originalTarget,
                  "refresh failure retains rows belonging to the same history target")
        try check(fixture.store.historyIsStale && fixture.store.historyHasLoaded
                    && fixture.store.historyErrorMessage != nil,
                  "a failed refresh labels retained data as stale instead of an empty successful result")
        let refreshed = Array((500...700).reversed())
        await fixture.service.replaceFirstHistory(with: refreshed)
        await fixture.store.retryHistory()
        try check(fixture.store.historyEntries.map(\.revision) == Array(refreshed.prefix(100)),
                  "a successful refresh replaces accumulated pages with the latest first page")
        try check(!fixture.store.historyIsStale && fixture.store.historyErrorMessage == nil
                    && fixture.store.historyHasMore,
                  "successful refresh clears the stale marker and computes a new paging boundary")
        let requests = await fixture.service.requests
        try check(requests.suffix(2).allSatisfy { $0.beforeRevision == nil && $0.limit == 101 },
                  "failed refresh and its retry both query HEAD with one page plus a probe")
    }

    @MainActor
    static func changingTargetDiscardsLateResponse() async throws {
        let fixture = try await makeFixture(revisions: [300, 299])
        await fixture.service.holdNextPage()
        let oldRequest = Task { await fixture.store.showHistory(for: fixture.first) }
        try await waitUntil { await fixture.service.hasPendingPage }
        await fixture.store.showHistory(for: fixture.second)
        try check(fixture.store.historyTarget?.workingCopy.id == fixture.second.id
                    && fixture.store.historyEntries.map(\.revision) == [900, 800],
                  "a new working-copy target can publish while the cancelled old service call remains pending")
        await fixture.service.finishPendingPage()
        await oldRequest.value
        let cancelled = await fixture.service.pendingCallerWasCancelled
        try check(cancelled, "changing history targets cancels the previous service call")
        try check(fixture.store.historyTarget?.workingCopy.id == fixture.second.id
                    && fixture.store.historyEntries.map(\.revision) == [900, 800]
                    && fixture.store.historyErrorMessage == nil,
                  "an obsolete service that ignores cancellation cannot overwrite a new target's rows or error")
    }

    @MainActor
    static func hiddenHistoryCanResume() async throws {
        let revisions = Array((1...101).reversed())
        let fixture = try await makeFixture(revisions: revisions)
        await fixture.store.showHistory(for: fixture.first)
        let firstPage = fixture.store.historyEntries
        await fixture.service.holdNextPage()
        let request = Task { await fixture.store.loadMoreHistory() }
        try await waitUntil { await fixture.service.hasPendingPage }
        try check(fixture.store.isLoadingMoreHistory, "paging exposes its own loading state")
        fixture.store.inspectorTab = .diff
        await fixture.service.finishPendingPage()
        await request.value
        try check(!fixture.store.isLoadingHistory && !fixture.store.isLoadingMoreHistory,
                  "hiding history clears its in-progress indicators")
        try check(fixture.store.historyEntries == firstPage,
                  "cancelling a hidden next page preserves already displayed history")
        fixture.store.inspectorTab = .history
        await fixture.store.ensureHistoryForSelection()
        try check(fixture.store.historyEntries.map(\.revision) == revisions
                    && fixture.store.historyHasLoaded && !fixture.store.historyHasMore,
                  "reentering cancelled history resumes the pending page rather than replacing earlier pages")
        let requests = await fixture.service.requests
        try check(requests.count == 3 && requests[1].beforeRevision == firstPage.last?.revision
                    && requests[2].beforeRevision == requests[1].beforeRevision,
                  "a hidden page and its resumed request share the same cursor")
    }

    @MainActor
    static func localRefreshInvalidatesPaging() async throws {
        let fixture = try await makeFixture(revisions: Array((1...301).reversed()))
        await fixture.store.showHistory(for: fixture.first)
        await fixture.store.loadMoreHistory()
        let original = fixture.store.historyEntries
        await fixture.service.holdNextPage()
        let oldPage = Task { await fixture.store.loadMoreHistory() }
        try await waitUntil { await fixture.service.hasPendingPage }
        await fixture.store.reloadSelectedWorkingCopy()
        try check(fixture.store.historyEntries == original && fixture.store.historyIsStale
                    && !fixture.store.canLoadMoreHistory && !fixture.store.isLoadingHistory,
                  "refreshing local status preserves history but prevents paging with the earlier working-copy state")

        let refreshed = Array((500...700).reversed())
        await fixture.service.replaceFirstHistory(with: refreshed)
        fixture.store.inspectorTab = .diff
        fixture.store.inspectorTab = .history
        await fixture.store.ensureHistoryForSelection()
        try check(fixture.store.historyEntries.map(\.revision) == Array(refreshed.prefix(100))
                    && !fixture.store.historyIsStale && fixture.store.canLoadMoreHistory,
                  "reentering invalidated history refreshes its first page before allowing further paging")
        let requests = await fixture.service.requests
        try check(requests.count == 4 && requests.last?.beforeRevision == nil,
                  "operation invalidation restarts at HEAD rather than retrying a page from the old state")

        await fixture.service.finishPendingPage()
        await oldPage.value
        let cancelled = await fixture.service.pendingCallerWasCancelled
        try check(cancelled && fixture.store.historyEntries.map(\.revision) == Array(refreshed.prefix(100))
                    && !fixture.store.historyIsStale,
                  "the page cancelled by local refresh cannot append late data after history has refreshed")
    }

    @MainActor
    private static func makeFixture(revisions: [Int]) async throws -> HistoryPagingFixture {
        let service = HistoryPagingFixtureService(firstRevisions: revisions)
        let store = SvnDockStore(service: service)
        try check(await store.load(), "history fixture working copies load")
        guard let first = store.workingCopies.first, let second = store.workingCopies.last,
              first.id != second.id else { throw HistoryPagingFailure(message: "missing fixture copies") }
        return HistoryPagingFixture(store: store, service: service, first: first, second: second)
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw HistoryPagingFailure(message: message) }
    }

    @MainActor
    private static func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard clock.now < deadline else { throw HistoryPagingFailure(message: "history fixture timed out") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private struct HistoryPagingFixture {
    let store: SvnDockStore
    let service: HistoryPagingFixtureService
    let first: SvnDockWorkingCopy
    let second: SvnDockWorkingCopy
}

private struct HistoryPagingFailure: Error { let message: String }

private actor HistoryPagingFixtureService: SvnDockServicing {
    struct Request: Sendable {
        let workingCopyID: UUID
        let relativePaths: [String]
        let limit: Int
        let beforeRevision: Int?
    }

    private let first = SvnDockWorkingCopy(name: "Alpha", rootURL: URL(fileURLWithPath: "/fixture/history-alpha"))
    private let second = SvnDockWorkingCopy(name: "Beta", rootURL: URL(fileURLWithPath: "/fixture/history-beta"))
    private var firstRevisions: [Int]
    private var shouldFail = false
    private var shouldHold = false
    private var nextOverride: [Int]?
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var requests: [Request] = []
    private(set) var pendingCallerWasCancelled = false

    init(firstRevisions: [Int]) { self.firstRevisions = firstRevisions }
    var hasPendingPage: Bool { pending != nil }
    func replaceFirstHistory(with revisions: [Int]) { firstRevisions = revisions }
    func overrideNextPage(with revisions: [Int]) { nextOverride = revisions }
    func failNextPage() { shouldFail = true }
    func holdNextPage() { shouldHold = true }
    func finishPendingPage() { pending?.resume(); pending = nil }

    func loadRegisteredWorkingCopies() async throws -> [SvnDockWorkingCopy] { [first, second] }
    func status(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockStatusSnapshot { .empty }
    func historyPage(for workingCopy: SvnDockWorkingCopy, relativePaths: [String], limit: Int,
                     beforeRevision: Int?) async throws -> [SvnDockLogEntry] {
        requests.append(.init(workingCopyID: workingCopy.id, relativePaths: relativePaths,
                              limit: limit, beforeRevision: beforeRevision))
        if shouldFail {
            shouldFail = false
            throw HistoryPagingFailure(message: "fixture history request failed")
        }
        let revisions = workingCopy.id == first.id ? firstRevisions : [900, 800]
        let result = nextOverride ?? Array(revisions.filter { revision in
            beforeRevision.map { revision < $0 } ?? true
        }.prefix(limit))
        nextOverride = nil
        if shouldHold {
            shouldHold = false
            await withCheckedContinuation { pending = $0 }
            // Deliberately return the captured response despite cancellation
            // to verify that Store generations reject obsolete data.
            pendingCallerWasCancelled = Task.isCancelled
        }
        return result.map { .init(revision: $0, author: nil, date: nil, message: "fixture r\($0)") }
    }
    func history(for workingCopy: SvnDockWorkingCopy, relativePaths: [String], limit: Int) async throws -> [SvnDockLogEntry] {
        throw HistoryPagingFailure(message: "paged history must use the cursor service API")
    }
    func registerWorkingCopy(at url: URL) async throws -> SvnDockWorkingCopy { throw unavailable }
    func unregisterWorkingCopy(id: UUID) async throws { throw unavailable }
    func directoryChildren(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> [SvnDockStatusEntry] { [] }
    func diff(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> String { throw unavailable }
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
    func addIgnoreRules(_ rules: [SvnDockIgnoreRule], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func cleanup(workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    private var unavailable: SvnDockServiceError { .unavailable("Unsupported history fixture operation") }
}
