import XCTest

final class LocalDifferenceRegressionTests: XCTestCase {
    func testReadOnlyWhitespaceClassificationAndOutputBounds() async throws {
        guard try await LocalDifferenceRegressionChecks.run() else {
            throw XCTSkip("SVN and svnadmin are unavailable")
        }
    }
}
