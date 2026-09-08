import XCTest

final class DifferenceFilterStoreRegressionTests: XCTestCase {
    func testFilteringPreservesStatusAndCommitChoices() async throws {
        try await DifferenceFilterStoreRegressionChecks.filteringPreservesStatusAndCommitChoices()
    }
    func testUnavailableComparisonsRemainVisibleAndRetry() async throws {
        try await DifferenceFilterStoreRegressionChecks.unavailableComparisonsRemainVisibleAndRetry()
    }
    func testDisablingRejectsLateResults() async throws {
        try await DifferenceFilterStoreRegressionChecks.disablingRejectsLateResults()
    }
    func testRefreshAndSelectionRejectLateResults() async throws {
        try await DifferenceFilterStoreRegressionChecks.refreshAndSelectionRejectLateResults()
    }
    func testMutationsInvalidateAndResumeClassification() async throws {
        try await DifferenceFilterStoreRegressionChecks.mutationsInvalidateAndResumeClassification()
    }
    func testUnrelatedPresentationsDoNotStrandComparisons() async throws {
        try await DifferenceFilterStoreRegressionChecks.unrelatedPresentationsDoNotStrandComparisons()
    }
}
