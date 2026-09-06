import XCTest

final class FinderBadgeServiceRegressionTests: XCTestCase {
    func testAuthoritativeFinderTargetsAndVisibleDirectoryBadges() async throws {
        try await FinderBadgeServiceRegressionChecks.run()
    }
}
