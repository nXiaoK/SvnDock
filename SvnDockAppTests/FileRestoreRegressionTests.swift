import XCTest

final class FileRestoreRegressionTests: XCTestCase {
    @MainActor
    func testHistoricalFileRestoreAndFinderConfirmation() async throws {
        try await FileRestoreRegressionChecks.run()
    }
}
