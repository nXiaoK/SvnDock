import XCTest

final class RemoteStoreRegressionTests: XCTestCase {
    func testRemoteChecksPreserveStateAndWorkingCopyIdentity() async throws {
        try await RemoteStoreRegressionChecks.run()
    }
}
