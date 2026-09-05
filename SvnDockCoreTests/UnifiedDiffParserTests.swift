import XCTest
@testable import SvnDockCore

final class UnifiedDiffParserTests: XCTestCase {
    func testParsesContextAndAlignsConsecutiveReplacementLines() {
        let diff = """
        --- Sources/App.swift (revision 14)
        +++ Sources/App.swift (working copy)
        @@ -10,4 +10,5 @@ struct App {
         keep before
        -old one
        -old two
        +new one
        +new two
        +new three
         keep after
        """

        let document = UnifiedDiffParser.parse(diff)

        XCTAssertEqual(document.oldFilePath, "Sources/App.swift")
        XCTAssertEqual(document.newFilePath, "Sources/App.swift")
        XCTAssertEqual(document.hunks.count, 1)
        XCTAssertEqual(document.hunks[0].heading, "struct App {")
        XCTAssertEqual(document.rows.map(\.kind), [
            .context, .change, .change, .addition, .context
        ])
        XCTAssertEqual(document.rows[0].oldLineNumber, 10)
        XCTAssertEqual(document.rows[0].newLineNumber, 10)
        XCTAssertEqual(document.rows[1].oldText, "old one")
        XCTAssertEqual(document.rows[1].newText, "new one")
        XCTAssertEqual(document.rows[2].oldText, "old two")
        XCTAssertEqual(document.rows[2].newText, "new two")
        XCTAssertNil(document.rows[3].oldLineNumber)
        XCTAssertEqual(document.rows[3].newLineNumber, 13)
        XCTAssertNil(document.rows[3].oldText)
        XCTAssertEqual(document.rows[3].newText, "new three")
        XCTAssertEqual(document.rows[4].oldLineNumber, 13)
        XCTAssertEqual(document.rows[4].newLineNumber, 14)
        XCTAssertNil(document.fallbackText)
    }

    func testAlignsPureDeletionHunk() {
        let document = UnifiedDiffParser.parse("""
        @@ -2,2 +2,0 @@
        -first
        -second
        """)

        XCTAssertEqual(document.rows.map(\.kind), [.deletion, .deletion])
        XCTAssertEqual(document.rows.map(\.oldLineNumber), [2, 3])
        XCTAssertEqual(document.rows.map(\.newLineNumber), [nil, nil])
        XCTAssertEqual(document.rows.map(\.oldText), ["first", "second"])
        XCTAssertEqual(document.rows.map(\.newText), [nil, nil])
    }

    func testAlignsPureAdditionHunk() {
        let document = UnifiedDiffParser.parse("""
        @@ -0,0 +1,2 @@
        +first
        +second
        """)

        XCTAssertEqual(document.rows.map(\.kind), [.addition, .addition])
        XCTAssertEqual(document.rows.map(\.oldLineNumber), [nil, nil])
        XCTAssertEqual(document.rows.map(\.newLineNumber), [1, 2])
        XCTAssertEqual(document.rows.map(\.oldText), [nil, nil])
        XCTAssertEqual(document.rows.map(\.newText), ["first", "second"])
    }

    func testParsesMultipleHunksAndDefaultsAnOmittedCountToOne() {
        let document = UnifiedDiffParser.parse("""
        --- notes.txt\t(revision 8)
        +++ notes.txt\t(working copy)
        @@ -1 +1 @@ title
        -before
        +after
        @@ -9 +9,2 @@ footer
         shared
        +inserted
        """)

        XCTAssertEqual(document.hunks.count, 2)
        XCTAssertEqual(document.hunks[0].oldCount, 1)
        XCTAssertEqual(document.hunks[0].newCount, 1)
        XCTAssertEqual(document.hunks[0].heading, "title")
        XCTAssertEqual(document.hunks[1].oldStart, 9)
        XCTAssertEqual(document.hunks[1].oldCount, 1)
        XCTAssertEqual(document.hunks[1].newCount, 2)
        XCTAssertEqual(document.hunks[1].heading, "footer")
        XCTAssertEqual(document.hunks[1].rows.map(\.kind), [.context, .addition])
        XCTAssertEqual(document.rows.count, 3)
    }

    func testNoNewlineMarkersAnnotateContentWithoutCreatingRows() {
        let document = UnifiedDiffParser.parse("""
        @@ -1 +1 @@
        -old ending
        \\ No newline at end of file
        +new ending
        \\ No newline at end of file
        """)

        XCTAssertEqual(document.rows.count, 1)
        XCTAssertEqual(document.rows[0].kind, .change)
        XCTAssertFalse(document.rows[0].oldHasTrailingNewline)
        XCTAssertFalse(document.rows[0].newHasTrailingNewline)
    }

    func testReturnsOriginalTextWhenThereAreNoTextHunks() {
        let output = """
        Index: Assets/logo.png
        ===================================================================
        Cannot display: file marked as a binary type.
        svn:mime-type = application/octet-stream
        """

        let document = UnifiedDiffParser.parse(output)

        XCTAssertTrue(document.hunks.isEmpty)
        XCTAssertTrue(document.rows.isEmpty)
        XCTAssertEqual(document.fallbackText, output)
    }

    func testEmptyOrMalformedHunkFallsBackToOriginalText() {
        let output = "@@ malformed @@\n"

        let document = UnifiedDiffParser.parse(output)

        XCTAssertTrue(document.hunks.isEmpty)
        XCTAssertEqual(document.fallbackText, output)
    }

    func testModelsAreHashableAndSendable() {
        let document = UnifiedDiffParser.parse("@@ -1 +1 @@\n same")

        assertSendable(document)
        XCTAssertEqual(Set(document.rows).count, 1)
    }

    func testCRLFAndMixedLineEndingsKeepAllHunks() {
        let document = UnifiedDiffParser.parse("--- 中文.md\r\n+++ 中文.md\r\n@@ -4 +4 @@\r\n-old\r\n+新行\r\n@@ -106 +109 @@\n-last\n+末行\n")
        XCTAssertEqual(document.hunks.count, 2)
        XCTAssertEqual(document.rows.map(\.newLineNumber), [4, 109])
        XCTAssertEqual(document.rows.map(\.newText), ["新行", "末行"])
    }

    func testUnifiedReplacementKeepsAllRemovalsBeforeInsertions() {
        let document = UnifiedDiffParser.parse("@@ -1,2 +1,2 @@\n-old 1\n-old 2\n+new 1\n+new 2\n\\ No newline at end of file\n")
        let rows = document.hunks[0].unifiedRows
        XCTAssertEqual(rows.map(\.kind), [.deletion, .deletion, .addition, .addition])
        XCTAssertEqual(rows.map { $0.oldText ?? $0.newText }, ["old 1", "old 2", "new 1", "new 2"])
        XCTAssertFalse(rows[3].newHasTrailingNewline)
    }

    func testPropertyChangesAreRetainedAlongsideText() {
        let properties = "Property changes on: file.txt\nAdded: svn:keywords\n## -0,0 +1 ##\n+Id\n"
        let document = UnifiedDiffParser.parse("@@ -1 +1 @@\n-old\n+new\n" + properties)
        XCTAssertEqual(document.hunks.count, 1)
        XCTAssertEqual(document.propertyChanges, properties)
    }

    func testIncompleteLaterHunkDoesNotSilentlyDisappear() {
        let text = "@@ -1 +1 @@\n-old\n+new\n@@ -9,2 +9,2 @@\n-truncated\n"
        let document = UnifiedDiffParser.parse(text)
        XCTAssertTrue(document.hunks.isEmpty)
        XCTAssertEqual(document.fallbackText, text)
    }

    private func assertSendable<T: Sendable>(_ value: T) {
        _ = value
    }
}
