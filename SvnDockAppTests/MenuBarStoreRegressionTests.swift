import XCTest

final class MenuBarStoreRegressionTests: XCTestCase {
    func testMenuBarSelectionAndWindowLifecycle() async throws {
        try await MenuBarStoreRegressionChecks.run()
    }
}
