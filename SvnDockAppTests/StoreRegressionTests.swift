import XCTest

final class StoreRegressionTests: XCTestCase {
    func testFailedStatusCannotAppearCleanOrRetainActions() async throws {
        try await StoreRegressionChecks.failedStatusCannotAppearCleanOrRetainActions()
    }
    func testSelectionCancelsDiff() async throws {
        try await StoreRegressionChecks.selectionCancelsDiff()
    }
    func testDirectoryRetryRejectsOldError() async throws {
        try await StoreRegressionChecks.directoryRetryRejectsOldError()
    }
}
