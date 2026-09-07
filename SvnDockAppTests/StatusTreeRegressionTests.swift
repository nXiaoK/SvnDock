import XCTest

final class StatusTreeRegressionTests: XCTestCase {
    func testHierarchyPreservesExplicitOperationTargets() throws {
        try StatusTreeRegressionChecks.run()
    }
}
