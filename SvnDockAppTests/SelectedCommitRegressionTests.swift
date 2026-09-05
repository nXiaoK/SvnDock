import XCTest

final class SelectedCommitRegressionTests: XCTestCase {
    func testRealSVNSelectedCommitScope() async throws {
        guard try await SelectedCommitRegressionChecks.run() else {
            throw XCTSkip("SVN and svnadmin are unavailable")
        }
    }
}
