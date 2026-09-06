import XCTest

final class FinderBadgeTests: XCTestCase {
    func testBadgeDerivationFreshnessAndObservationRequests() async throws {
        try await FinderBadgeRegressionChecks.run()
    }
}
