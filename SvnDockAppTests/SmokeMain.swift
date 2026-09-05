import Foundation

@main
struct AppRegressionSmoke {
    static func main() async throws {
        try await StoreRegressionChecks.selectionCancelsDiff()
        try await StoreRegressionChecks.directoryRetryRejectsOldError()
        try ViewsRegressionChecks.snapshotStorageAndGrouping()
        try ViewsRegressionChecks.diffPresentationPreservesRows()
        try await ViewsRegressionChecks.clearedDiffDiscardsPresentation()
        try await ViewsRegressionChecks.historySelectionAndFiltering()
        try await ViewsRegressionChecks.historyDiffCacheRetainsRecentlyUsedEntries()
        print("App regression checks passed")
    }
}
