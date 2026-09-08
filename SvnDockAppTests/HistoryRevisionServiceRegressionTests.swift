import XCTest

final class HistoryRevisionServiceRegressionTests: XCTestCase {
    func testCopiedDeletionHistoryIncludesImplicitDescendants() async throws {
        guard try await HistoryRevisionServiceRegressionChecks.run() else {
            throw XCTSkip("SVN and svnadmin are unavailable")
        }
    }
}
