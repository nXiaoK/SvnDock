import XCTest

final class MissingRevertRegressionTests: XCTestCase {
    func testAbsentDirectoriesRestoreRecursively() async throws {
        try await MissingRevertRegressionChecks.absentDirectoriesRestoreRecursively()
    }

    func testPropertyChangesStayShallow() async throws {
        try await MissingRevertRegressionChecks.propertyChangesStayShallow()
    }

    func testFreshStatusPreventsStaleRecursion() async throws {
        try await MissingRevertRegressionChecks.freshStatusPreventsStaleRecursion()
    }

    func testBoundaryChangesPreventMutation() async throws {
        try await MissingRevertRegressionChecks.boundaryChangesPreventMutation()
    }

    func testStatusRequestsAreBounded() async throws {
        try await MissingRevertRegressionChecks.statusRequestsAreBounded()
    }

    func testAmbiguousAliasesDoNotRevert() async throws {
        try await MissingRevertRegressionChecks.ambiguousAliasesDoNotRevert()
    }
}
