import XCTest

final class IgnoreRecommendationRegressionTests: XCTestCase {
    func testRecommendedIgnoresPreserveContentAndExplicitScope() async throws {
        try await IgnoreRecommendationRegressionChecks.run()
    }
}
