import Foundation
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum HistoryQueryRegressionChecks {
    static func run() throws {
        try filtersLoadedEntries()
        try parsesRevisionJumps()
        try invalidatesHiddenSelection()
    }

    static func filtersLoadedEntries() throws {
        let entries = [
            SvnDockLogEntry(revision: 123, author: "Alice", date: nil, message: "Fix 登录 flow"),
            SvnDockLogEntry(revision: 122, author: "Bob", date: nil, message: "Update documentation"),
            SvnDockLogEntry(revision: 121, author: "ALICE", date: nil, message: "Improve logging"),
            SvnDockLogEntry(revision: 120, author: nil, date: nil, message: "")
        ]
        try check(SvnDockHistoryQuery(text: " \n", author: " ").filter(entries) == entries,
                  "blank filters preserve the loaded order and records without metadata")
        try check(SvnDockHistoryQuery(text: " 登录 ").filter(entries).map(\.revision) == [123],
                  "message filtering supports Unicode and surrounding whitespace")
        try check(SvnDockHistoryQuery(text: "alice").filter(entries).map(\.revision) == [123, 121],
                  "the general query also matches authors without case sensitivity")
        try check(SvnDockHistoryQuery(text: "R122").filter(entries).map(\.revision) == [122],
                  "revision labels are searchable in the loaded collection")
        try check(SvnDockHistoryQuery(text: "123").filter(entries).map(\.revision) == [123],
                  "numeric queries find loaded revision numbers")
        try check(SvnDockHistoryQuery(text: "logging", author: " alice ").filter(entries).map(\.revision) == [121],
                  "the author field narrows rather than expands the general query")
        try check(SvnDockHistoryQuery(text: "logging", author: "Bob").filter(entries).isEmpty,
                  "a combined query cannot match an entry that violates the author constraint")
        try check(SvnDockHistoryQuery(author: "nobody").filter(entries).isEmpty,
                  "missing authors are not treated as an invented searchable author")

        let query = SvnDockHistoryQuery(text: "older fix")
        try check(query.filter(entries).isEmpty, "an unloaded match is not fabricated")
        let older = SvnDockLogEntry(revision: 100, author: "Alice", date: nil, message: "Older fix")
        try check(query.filter(entries + [older]) == [older],
                  "loading another page makes its matching records visible without resetting the query")
    }

    static func parsesRevisionJumps() throws {
        for input in ["123", "r123", "R123", " \nr123\t", "r000123"] {
            try check(SvnDockHistoryQuery.revisionNumber(from: input) == 123,
                      "revision jump accepts one explicit positive revision: \(input)")
        }
        for input in ["", "r", "0", "r0", "-1", "+1", "1:2", "HEAD", "BASE", "r 1", "1 2", "1\n2", "１２３", String(repeating: "9", count: 100)] {
            try check(SvnDockHistoryQuery.revisionNumber(from: input) == nil,
                      "revision jump rejects empty, symbolic, ranged, signed, non-ASCII and overflowing values: \(input)")
        }
    }

    static func invalidatesHiddenSelection() throws {
        let entries = [SvnDockLogEntry(revision: 123, author: "Alice", date: nil, message: "fix")]
        try check(SvnDockHistoryQuery.visibleSelection(revision: 123, selectedTargetID: "copy-a::path", currentTargetID: "copy-a::path", entries: entries) == 123,
                  "a visible selection retains its detail in the same target")
        try check(SvnDockHistoryQuery.visibleSelection(revision: 123, selectedTargetID: "copy-a::path", currentTargetID: "copy-b::path", entries: entries) == nil,
                  "the same revision number in another repository cannot retain the previous detail")
        try check(SvnDockHistoryQuery.visibleSelection(revision: 123, selectedTargetID: "copy-a::path", currentTargetID: "copy-a::other", entries: entries) == nil,
                  "switching paths invalidates the previous selection")
        try check(SvnDockHistoryQuery.visibleSelection(revision: 123, selectedTargetID: "copy-a::path", currentTargetID: "copy-a::path", entries: []) == nil,
                  "filtering out the selected revision removes its detail immediately")
        try check(SvnDockHistoryQuery.visibleSelection(revision: 123, selectedTargetID: nil, currentTargetID: nil, entries: entries) == nil,
                  "unscoped selections cannot attach a detail to an unknown repository")
    }

    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    private struct Failure: Error { let message: String }
}
