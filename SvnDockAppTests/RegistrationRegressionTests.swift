import XCTest

final class RegistrationRegressionTests: XCTestCase {
    func testRegistrationUsesRootMetadata() async throws {
        try await RegistrationRegressionChecks.run()
    }
}
