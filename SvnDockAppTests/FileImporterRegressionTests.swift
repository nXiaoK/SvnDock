import XCTest

final class FileImporterRegressionTests: XCTestCase {
    @MainActor
    func testSharedImporterLifecycle() async throws {
        try await FileImporterRegressionChecks.run()
    }
}
