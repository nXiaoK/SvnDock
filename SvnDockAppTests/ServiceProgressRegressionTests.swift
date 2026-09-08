import XCTest

final class ServiceProgressRegressionTests: XCTestCase {
    func testLiveServiceProgressAndTransactionBoundaries() async throws {
        guard try await ServiceProgressRegressionChecks.run() else {
            throw XCTSkip("SVN and svnadmin are unavailable")
        }
    }
}
