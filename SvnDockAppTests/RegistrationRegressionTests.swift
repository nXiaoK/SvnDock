import XCTest

final class RegistrationRegressionTests: XCTestCase {
    func testRegistrationPreservesRootPathsAndMetadata() async throws {
        try await RegistrationRegressionChecks.run()
    }
}
