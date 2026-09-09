import XCTest

final class CheckoutRegressionTests: XCTestCase {
    @MainActor
    func testCheckoutAndRegistration() async throws {
        try await CheckoutRegressionChecks.run()
    }
}
