import XCTest

final class LargeDirectoryDeletionRegressionTests: XCTestCase {
    func testLargeDeletedTreePreviewAndExactSelectedCommit() async throws {
        guard try await LargeDirectoryDeletionRegressionChecks.run() else {
            throw XCTSkip("SVN and svnadmin are unavailable")
        }
    }
}
