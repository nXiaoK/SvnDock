import XCTest

final class ConflictReviewRegressionTests: XCTestCase {
    func testSelectionAndConsent() async throws {
        try await ConflictReviewRegressionChecks.selectionAndConsent()
    }
    func testFrozenReviewAndPreview() async throws {
        try await ConflictReviewRegressionChecks.frozenReviewAndPreview()
    }
    func testOperationOutcomes() async throws {
        try await ConflictReviewRegressionChecks.operationOutcomes()
    }
}
