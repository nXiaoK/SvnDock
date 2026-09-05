import XCTest

final class MissingStatusRegressionTests: XCTestCase {
    func testMissingStatusClassification() async throws {
        try await MissingStatusRegressionChecks.run()
    }
}
