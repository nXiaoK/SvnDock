import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum LargeDiffPresentationRegressionChecks {
    @MainActor
    static func run() async throws {
        try largeDeletionUsesBoundedPreview()
        try longLinesAndManyLinesUseBoundedPreview()
        try unicodeExcerptPreservesValidCharacters()
        try ordinaryDiffRetainsFullPresentation()
        try await modelRemainsResponsiveAndDiscardsObsoleteLoads()
        print("Large diff presentation regression checks passed")
    }

    static func largeDeletionUsesBoundedPreview() throws {
        // Deleting a project produces thousands of file headers as well as
        // removed content. The preview must not build a row graph for it.
        let filePatch = """
        Index: deleted-project/source.java
        ===================================================================
        --- deleted-project/source.java\t(revision 1)
        +++ deleted-project/source.java\t(nonexistent)
        @@ -1,3 +0,0 @@
        -package example;
        -public class Source {
        -}

        """
        let text = String(repeating: filePatch, count: 6_000)
        try check(text.utf8.count > 1_048_576, "fixture covers a multi-megabyte deleted directory")
        let presentation = DiffPresentation(text: text)
        try checkLimited(presentation, original: text)
        try check(presentation.displayText.hasPrefix("Index: deleted-project/source.java\n"),
                  "limited deletion previews preserve the beginning of the SVN output")
    }

    static func longLinesAndManyLinesUseBoundedPreview() throws {
        let longLine = "--- old\n+++ new\n@@ -1 +1 @@\n-old\n+" + String(repeating: "x", count: 16_385) + "\n"
        try check(longLine.utf8.count < 1_048_576, "long-line fixture stays below the overall byte limit")
        try checkLimited(DiffPresentation(text: longLine), original: longLine)

        let manyLines = "--- old\n+++ new\n@@ -1,11000 +0,0 @@\n" + String(repeating: "-a\n", count: 11_000)
        try check(manyLines.utf8.count < 1_048_576, "line-count fixture stays below the overall byte limit")
        try checkLimited(DiffPresentation(text: manyLines), original: manyLines)

        // The byte guard must also work when neither individual lines nor the
        // total line count cross their limits.
        let wideLines = String(repeating: String(repeating: "x", count: 1_024) + "\n", count: 1_100)
        try checkLimited(DiffPresentation(text: wideLines), original: wideLines)
    }

    static func unicodeExcerptPreservesValidCharacters() throws {
        let line = "-文件🧪 café e\u{301} " + String(repeating: "界🙂", count: 160) + "\n"
        let text = String(repeating: line, count: 1_200)
        let presentation = DiffPresentation(text: text)
        try checkLimited(presentation, original: text)
        try check(presentation.displayText.hasPrefix(line), "Unicode preview keeps complete initial lines")
        try check(!presentation.displayText.contains("\u{FFFD}"),
                  "truncating near the byte limit must not split a UTF-8 scalar")
        try check(String(data: Data(presentation.displayText.utf8), encoding: .utf8) == presentation.displayText,
                  "the bounded excerpt remains valid UTF-8")
    }

    static func ordinaryDiffRetainsFullPresentation() throws {
        let text = """
        Index: src/example.swift
        ===================================================================
        --- src/example.swift\t(revision 1)
        +++ src/example.swift\t(working copy)
        @@ -1,3 +1,4 @@
         unchanged
        -old first
        -old second
        +new first
        +new second
        +new third

        """
        let presentation = DiffPresentation(text: text)
        try check(!presentation.isPreviewLimited, "ordinary files retain the structured diff")
        try check(presentation.displayText == text, "ordinary raw mode retains every original byte")
        try check(presentation.document.hunks.count == 1 && !presentation.unifiedItems.isEmpty
                  && !presentation.sideBySideItems.isEmpty, "ordinary files retain both rendered layouts")
        try check(presentation.additions == 3 && presentation.deletions == 2,
                  "ordinary files retain exact addition and deletion counts")
    }

    @MainActor
    static func modelRemainsResponsiveAndDiscardsObsoleteLoads() async throws {
        let model = DiffPresentationModel()
        let normal = "--- old\n+++ new\n@@ -1 +1 @@\n-old\n+new\n"
        let huge = String(repeating: "x", count: 20 * 1_048_576)
        let clock = ContinuousClock()
        let startedAt = clock.now
        var mainActorAdvanced = false
        let heartbeat = Task { @MainActor in mainActorAdvanced = true }
        await model.load(text: huge)
        try check(mainActorAdvanced, "loading a large preview yields the main actor to other work")
        await heartbeat.value
        try check(startedAt.duration(to: clock.now) < .seconds(3),
                  "a twenty-megabyte single line must return a bounded preview promptly")
        try check(model.presentation?.isPreviewLimited == true && model.statistics == nil,
                  "a limited preview publishes no misleading zero change counts")

        await model.load(text: normal)
        try check(model.statistics == DiffStatistics(additions: 1, deletions: 1, hunks: 1),
                  "a normal diff restores exact statistics after a limited preview")

        // The flag runs in the same main-actor turn as load's synchronous
        // prefix, so clear cannot occur before this request has started.
        // Unlike polling for nil, this also works when a bounded load finishes
        // before the polling task resumes.
        var replacementStarted = false
        let replacement = Task { @MainActor in
            replacementStarted = true
            await model.load(text: huge)
        }
        while !replacementStarted { await Task.yield() }
        model.clear()
        await replacement.value
        try check(model.presentation == nil && model.statistics == nil,
                  "cleared large loads cannot publish an obsolete preview or statistics")

        var obsoleteStarted = false
        let obsolete = Task { @MainActor in
            obsoleteStarted = true
            await model.load(text: huge)
        }
        while !obsoleteStarted { await Task.yield() }
        obsolete.cancel()
        await model.load(text: normal)
        await obsolete.value
        try check(model.presentation?.displayText == normal
                  && model.statistics == DiffStatistics(additions: 1, deletions: 1, hunks: 1),
                  "cancelled older requests cannot overwrite the next selected file")

        let cancelledBeforeStart = Task { @MainActor in await model.load(text: huge) }
        cancelledBeforeStart.cancel()
        await cancelledBeforeStart.value
        try check(model.presentation?.displayText == normal,
                  "an already-cancelled request leaves the current preview intact")
    }

    private static func checkLimited(_ presentation: DiffPresentation, original: String) throws {
        try check(presentation.isPreviewLimited, "large output must use the limited preview")
        try check(presentation.document.hunks.isEmpty && presentation.unifiedItems.isEmpty
                  && presentation.sideBySideItems.isEmpty,
                  "large output must skip parsing and flattening thousands of diff rows")
        try check(presentation.displayText != original, "a limited preview must not render the complete output")
        try check(presentation.displayText.utf8.count <= 32_768 + 256,
                  "the raw excerpt stays within its byte budget plus a short truncation notice")
        try check(presentation.displayText.utf8.filter { $0 == 10 }.count <= 202,
                  "the raw excerpt stays within its line budget plus a short truncation notice")
    }

    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }

    private struct Failure: Error { let message: String }
}
