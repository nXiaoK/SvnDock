import XCTest

final class FinderRoutingRegressionTests: XCTestCase {
    func testFinderTargetsCommitScopeAndQueueLifecycle() async throws {
        try await FinderRoutingRegressionChecks.run()
    }
}
