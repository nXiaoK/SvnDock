import XCTest

final class StoreProgressRegressionTests: XCTestCase {
    func testCommitReportsLiveProgressWithoutInvalidatingTheStore() async throws {
        try await StoreProgressRegressionChecks.commitReportsLiveProgressWithoutInvalidatingTheStore()
    }

    func testUpdateProgressTracksEachCopyAndRejectsLateReports() async throws {
        try await StoreProgressRegressionChecks.updateProgressTracksEachCopyAndRejectsLateReports()
    }

    func testUnsuccessfulCommitClearsProgress() async throws {
        try await StoreProgressRegressionChecks.unsuccessfulCommitClearsProgress()
    }
}
