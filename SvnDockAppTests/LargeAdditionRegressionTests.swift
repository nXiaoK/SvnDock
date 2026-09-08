import XCTest

final class LargeAdditionRegressionTests: XCTestCase {
    func testLargeAdditionBoundariesAndRealSVNSelectionScope() async throws {
        guard try await LargeAdditionRegressionChecks.run() else {
            throw XCTSkip("SVN and svnadmin are unavailable")
        }
    }
}
