import XCTest

final class ReviewInteractionRegressionTests: XCTestCase {
    func testLocalPreviewBoundaries() throws {
        try ReviewInteractionRegressionChecks.localPreviewBoundaries()
    }

    func testContextSelectionPreservesScope() throws {
        try ReviewInteractionRegressionChecks.contextSelectionPreservesScope()
    }
}
