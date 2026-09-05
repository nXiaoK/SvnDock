import XCTest

final class OperationStoreRegressionTests: XCTestCase {
    func testUpdateAllRetainsIndividualResults() async throws {
        try await OperationStoreRegressionChecks.updateAllRetainsIndividualResults()
    }

    func testCancelledUpdateStopsRemainingCopies() async throws {
        try await OperationStoreRegressionChecks.cancelledUpdateStopsRemainingCopies()
    }

    func testCommitOutcomesReflectExecutionCertainty() async throws {
        try await OperationStoreRegressionChecks.commitOutcomesReflectExecutionCertainty()
    }
}
