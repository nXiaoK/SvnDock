import XCTest

final class PreferencesRegressionTests: XCTestCase {
    func testPreferencesReflectSystemLoginStateAndPersistMenuBarChoice() async throws {
        try await PreferencesRegressionChecks.run()
    }
}
