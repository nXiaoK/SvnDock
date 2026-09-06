import XCTest

final class HistoryPageServiceRegressionTests: XCTestCase {
    func testHistoryCursorCommandsAndRealRepositoryPages() async throws {
        guard try await HistoryPageServiceRegressionChecks.run() else {
            throw XCTSkip("SVN and svnadmin are unavailable")
        }
    }
}
