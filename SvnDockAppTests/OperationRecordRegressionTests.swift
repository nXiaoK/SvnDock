import XCTest

final class OperationRecordRegressionTests: XCTestCase {
    func testOperationRecordOutcomesCopyingAndRetention() throws {
        try OperationRecordRegressionChecks.run()
    }
}
