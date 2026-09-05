import XCTest

final class ViewsRegressionTests: XCTestCase {
    func testSnapshotStorageAndGrouping() throws {
        try ViewsRegressionChecks.snapshotStorageAndGrouping()
    }

    func testDiffPresentationPreservesRows() throws {
        try ViewsRegressionChecks.diffPresentationPreservesRows()
    }

    func testClearedDiffDiscardsPresentation() async throws {
        try await ViewsRegressionChecks.clearedDiffDiscardsPresentation()
    }

    func testHistorySelectionAndFiltering() async throws {
        try await ViewsRegressionChecks.historySelectionAndFiltering()
    }

    func testHistoryDiffCacheRetainsRecentlyUsedEntries() async throws {
        try await ViewsRegressionChecks.historyDiffCacheRetainsRecentlyUsedEntries()
    }
}
