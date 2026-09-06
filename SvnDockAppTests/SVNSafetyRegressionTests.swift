import XCTest

final class SVNSafetyRegressionTests: XCTestCase {
    func testRealSVNDataSafety() async throws {
        try await SVNSafetyRegressionChecks.run()
    }
}
