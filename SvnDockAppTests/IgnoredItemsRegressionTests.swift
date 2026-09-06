import XCTest

final class IgnoredItemsRegressionTests: XCTestCase {
    func testRealIgnoredRuleRemovalAndBoundaries() async throws {
        guard try await IgnoredItemsRegressionChecks.run() else {
            throw XCTSkip("SVN and svnadmin are unavailable")
        }
    }
}
