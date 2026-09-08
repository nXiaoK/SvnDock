import XCTest

final class LargeDiffPresentationRegressionTests: XCTestCase {
    func testLargeDeletionUsesBoundedPreview() throws {
        try LargeDiffPresentationRegressionChecks.largeDeletionUsesBoundedPreview()
    }

    func testLongLinesAndManyLinesUseBoundedPreview() throws {
        try LargeDiffPresentationRegressionChecks.longLinesAndManyLinesUseBoundedPreview()
    }

    func testUnicodeExcerptPreservesValidCharacters() throws {
        try LargeDiffPresentationRegressionChecks.unicodeExcerptPreservesValidCharacters()
    }

    func testOrdinaryDiffRetainsFullPresentation() throws {
        try LargeDiffPresentationRegressionChecks.ordinaryDiffRetainsFullPresentation()
    }

    func testModelRemainsResponsiveAndDiscardsObsoleteLoads() async throws {
        try await LargeDiffPresentationRegressionChecks.modelRemainsResponsiveAndDiscardsObsoleteLoads()
    }
}
