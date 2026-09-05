import XCTest

final class CommitDraftRegressionTests: XCTestCase {
    func testDraftRecoveryIsolationAndCommitLifecycle() async throws {
        try await CommitDraftRegressionChecks.run()
    }
}
