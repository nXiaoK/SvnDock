import XCTest

final class IgnoredItemsStoreRegressionTests: XCTestCase {
    func testIgnoredLoadingAndRemovalInteraction() async throws {
        try await IgnoredItemsStoreRegressionChecks.run()
    }
}
