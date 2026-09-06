import XCTest

final class HistoryQueryRegressionTests: XCTestCase {
    func testFiltersLoadedEntries() throws {
        try HistoryQueryRegressionChecks.filtersLoadedEntries()
    }

    func testParsesRevisionJumps() throws {
        try HistoryQueryRegressionChecks.parsesRevisionJumps()
    }

    func testInvalidatesHiddenSelection() throws {
        try HistoryQueryRegressionChecks.invalidatesHiddenSelection()
    }
}
