import XCTest

final class ResolveServiceRegressionTests: XCTestCase {
    func testVerifiedResolveResultsAndRealConflicts() async throws {
        guard try await ResolveServiceRegressionChecks.run() else {
            throw XCTSkip("SVN and svnadmin are unavailable")
        }
    }
}
