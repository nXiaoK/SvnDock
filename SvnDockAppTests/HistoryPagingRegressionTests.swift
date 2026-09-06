import XCTest

final class HistoryPagingRegressionTests: XCTestCase {
    func testPageBoundariesAndEmptyTail() async throws {
        try await HistoryPagingRegressionChecks.pageBoundariesAndEmptyTail()
    }

    func testSparseRevisionsAndNewHead() async throws {
        try await HistoryPagingRegressionChecks.sparseRevisionsAndNewHead()
    }

    func testFailedPageRetriesItsCursor() async throws {
        try await HistoryPagingRegressionChecks.failedPageRetriesItsCursor()
    }

    func testRefreshRetainsThenReplacesHistory() async throws {
        try await HistoryPagingRegressionChecks.refreshRetainsThenReplacesHistory()
    }

    func testChangingTargetDiscardsLateResponse() async throws {
        try await HistoryPagingRegressionChecks.changingTargetDiscardsLateResponse()
    }

    func testHiddenHistoryCanResume() async throws {
        try await HistoryPagingRegressionChecks.hiddenHistoryCanResume()
    }

    func testLocalRefreshInvalidatesPaging() async throws {
        try await HistoryPagingRegressionChecks.localRefreshInvalidatesPaging()
    }
}
