import XCTest

final class MissingDeletionRegressionTests: XCTestCase {
    func testConfirmationKeepsCapturedTargets() async throws {
        try await MissingDeletionRegressionChecks.confirmationKeepsCapturedTargets()
    }

    func testCancellationDoesNotDelete() async throws {
        try await MissingDeletionRegressionChecks.cancellationDoesNotDelete()
    }

    func testInvalidRequestsDoNotRetargetSelection() async throws {
        try await MissingDeletionRegressionChecks.invalidRequestsDoNotRetargetSelection()
    }

    func testUnselectedContextUsesOnlyClickedEntry() async throws {
        try await MissingDeletionRegressionChecks.unselectedContextUsesOnlyClickedEntry()
    }

    func testAllMissingUsesOnlyVersionedMissingEntries() async throws {
        try await MissingDeletionRegressionChecks.allMissingUsesOnlyVersionedMissingEntries()
    }

    func testWorkingCopySwitchDoesNotPublishOldResults() async throws {
        try await MissingDeletionRegressionChecks.workingCopySwitchDoesNotPublishOldResults()
    }

    func testFailureCanBeRetried() async throws {
        try await MissingDeletionRegressionChecks.failureCanBeRetried()
    }
}
