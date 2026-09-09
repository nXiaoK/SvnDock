import XCTest

final class CommitCommandPreviewRegressionTests: XCTestCase {
    @MainActor
    func testCommitCommandPreviewMatchesExecution() async throws {
        try await CommitCommandPreviewRegressionChecks.run()
    }
}
