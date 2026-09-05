import XCTest

final class WorkingCopyStatusRegressionTests: XCTestCase {
    func testLocalAndServerStatusRemainAccurate() throws {
        try WorkingCopyStatusRegressionChecks.run()
    }
}
