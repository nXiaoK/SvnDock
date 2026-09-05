import Foundation

@main
struct AppRegressionSmoke {
    static func main() async throws {
        try await CommitDraftRegressionChecks.run()
        try await SelectedCommitRegressionChecks.run()
        try ReviewInteractionRegressionChecks.localPreviewBoundaries()
        try ReviewInteractionRegressionChecks.contextSelectionPreservesScope()
        try WorkingCopyStatusRegressionChecks.run()
        try await RemoteStoreRegressionChecks.run()
        try await StoreRegressionChecks.selectionCancelsDiff()
        try await StoreRegressionChecks.directoryRetryRejectsOldError()
        try await MissingDeletionRegressionChecks.run()
        try await MissingStatusRegressionChecks.run()
        try await MissingRevertRegressionChecks.run()
        try await RegistrationRegressionChecks.run()
        try await PreferencesRegressionChecks.run()
        try await MenuBarStoreRegressionChecks.run()
        try ViewsRegressionChecks.snapshotStorageAndGrouping()
        try ViewsRegressionChecks.diffPresentationPreservesRows()
        try await ViewsRegressionChecks.clearedDiffDiscardsPresentation()
        try await ViewsRegressionChecks.historySelectionAndFiltering()
        try await ViewsRegressionChecks.historyDiffCacheRetainsRecentlyUsedEntries()
        print("App regression checks passed")
    }
}
