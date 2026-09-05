import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum ViewsRegressionChecks {
    static func snapshotStorageAndGrouping() throws {
        let copyID = UUID()
        func entry(_ path: String, _ status: SvnDockStatusKind) -> SvnDockStatusEntry {
            .init(workingCopyID: copyID, relativePath: path, nodeKind: .file, status: status)
        }
        let clean = SvnDockStatusSnapshot(entries: (0..<10_000).map { entry("file-\($0)", .clean) })
        try check(clean.committableEntries.capacity == 0, "clean snapshots must not reserve space for committable entries")
        try check(sharesStorage(clean.entries, clean.groupedEntries), "ungrouped statuses share storage")
        let changed = SvnDockStatusSnapshot(entries: (0..<10_000).map { entry("file-\($0)", .modified) })
        try check(sharesStorage(changed.entries, changed.committableEntries), "fully committable snapshots share storage")
        try check(changed.counts.changed == 10_000, "shared committable snapshots retain status counts")

        let grouped = SvnDockStatusSnapshot(entries: [
            entry("missing", .missing), entry("missing/nested", .missing),
            entry("missing/nested/file", .missing), entry("edited", .modified),
            entry("new", .unversioned)
        ])
        try check(grouped.groupedMissingCount == 2 && grouped.groupedEntries.count == 3,
                  "missing descendants remain grouped under their topmost missing ancestor")
        try check(grouped.groupedEntries.first { $0.relativePath == "missing" }?.missingDescendantCount == 2,
                  "missing group counts include nested descendants")
        try check(grouped.entries.count == 5 && grouped.missingEntries.count == 3,
                  "full status data remains available to operations")
        try check(grouped.committableEntries.map(\.relativePath) == ["edited"], "only committable changes are included")
    }

    static func diffPresentationPreservesRows() throws {
        let patch = """
        --- old.txt
        +++ new.txt
        @@ -1,4 +1,5 @@
         keep
        -old one
        -old two
        +new one
        +new two
        +new three
         tail
        @@ -10 +11 @@
        -old end
        \\ No newline at end of file
        +new end
        \\ No newline at end of file
        """
        let presentation = DiffPresentation(text: patch)
        func rows(_ items: [DiffPresentation.Item]) -> [UnifiedDiffRow] {
            items.compactMap { item in
                guard case let .line(hunk, row, kind) = item.content else { return nil }
                return presentation.row(hunk: hunk, index: row, kind: kind)
            }
        }
        let unified = rows(presentation.unifiedItems)
        try check(unified.map { $0.newText ?? $0.oldText ?? "" } == [
            "keep", "old one", "old two", "new one", "new two", "new three", "tail", "old end", "new end"
        ], "unified rendering keeps deletions before additions in every block")
        try check(unified.map(\.kind) == [.context, .deletion, .deletion, .addition,
                                          .addition, .addition, .context, .deletion, .addition],
                  "unified coordinates preserve each row's kind")
        try check(unified[7].oldHasTrailingNewline == false && unified[8].newHasTrailingNewline == false,
                  "projection preserves missing-newline markers")
        try check(rows(presentation.sideBySideItems) == presentation.document.rows,
                  "side-by-side rendering preserves aligned replacement rows")
        try check(presentation.additions == 4 && presentation.deletions == 3,
                  "compact presentation retains diff statistics")
        try check(MemoryLayout<DiffPresentation.Item>.stride < MemoryLayout<UnifiedDiffRow>.stride,
                  "flattened presentation metadata is smaller than a copied diff row")
    }

    @MainActor
    static func clearedDiffDiscardsPresentation() async throws {
        let model = DiffPresentationModel()
        let patch = "--- old\n+++ new\n@@ -1 +1 @@\n-old\n+new\n"
        await model.load(text: patch)
        try check(model.statistics == DiffStatistics(additions: 1, deletions: 1, hunks: 1),
                  "loaded diff publishes its statistics")
        model.clear()
        try check(model.presentation == nil && model.statistics == nil,
                  "cleared diff releases its document and previous statistics")

        // load() clears the old presentation before it awaits its worker;
        // observing that state lets this check invalidate an in-flight parse.
        await model.load(text: patch)
        let lines = (0..<10_000).map { "-old \($0)\n+new \($0)" }.joined(separator: "\n")
        let replacement = Task {
            await model.load(text: "--- old\n+++ new\n@@ -1,10000 +1,10000 @@\n" + lines)
        }
        try await waitUntil { model.presentation == nil }
        model.clear()
        await replacement.value
        try check(model.presentation == nil && model.statistics == nil,
                  "an obsolete parse cannot restore cleared statistics")
    }

    @MainActor
    static func historySelectionAndFiltering() async throws {
        let copyID = UUID()
        let changes = [
            SVNChangedPath(path: "/folder", action: .modified, kind: .directory),
            SVNChangedPath(path: "/first.txt", action: .modified, kind: .file),
            SVNChangedPath(path: "/second.txt", action: .added, kind: .file,
                           copyFromPath: "/来源.txt", copyFromRevision: 1)
        ]
        let model = HistoryRevisionModel(detailsLoader: { request in
            details(revision: request.revision, changes: changes)
        }, diffLoader: { _, change, _ in change.path })
        await model.load(.init(workingCopyID: copyID, revision: 2, preferredPath: "/first.txt"))
        try check(model.selectedPath == "/first.txt", "initial preferred history path is selected")
        await model.load(.init(workingCopyID: copyID, revision: 3, preferredPath: "/second.txt"))
        try check(model.selectedPath == "/second.txt", "new revisions honor their own preferred path")
        await model.load(.init(workingCopyID: copyID, revision: 3, preferredPath: "/first.txt"))
        try check(model.selectedPath == "/first.txt", "updated requests within a revision honor the new preferred path")
        model.pathQuery = "first"
        model.pathQuery = " 来源 "
        try await waitUntil { !model.isFiltering }
        try check(model.filteredChanges.map(\.path) == ["/second.txt"], "latest filter matches normalized copy-source paths")
        model.pathQuery = "no match"
        model.cancel()
        try await Task.sleep(for: .milliseconds(200))
        try check(!model.isFiltering && model.filteredChanges.map(\.path) == ["/second.txt"],
                  "cancelled filtering cannot replace visible history paths")
    }

    @MainActor
    static func historyDiffCacheRetainsRecentlyUsedEntries() async throws {
        let changes = (0..<13).map { SVNChangedPath(path: "/file-\($0)", action: .modified, kind: .file) }
        let counter = DiffLoadCounter()
        let model = HistoryRevisionModel(detailsLoader: { request in
            details(revision: request.revision, changes: changes)
        }, diffLoader: { _, change, _ in await counter.load(path: change.path) })
        await model.load(.init(workingCopyID: UUID(), revision: 2))
        try await waitUntil { !model.isLoadingDiff }
        for change in changes.dropFirst().dropLast() {
            model.select(change.path)
            try await waitUntil { !model.isLoadingDiff }
        }
        model.select(changes[0].path)
        model.select(changes[12].path)
        try await waitUntil { !model.isLoadingDiff }
        model.select(changes[0].path)
        try await waitUntil { !model.isLoadingDiff }
        let count = await counter.count
        try check(count == 13, "cache eviction retains recently viewed diffs without reloading them")
        model.cancel()
    }

    private static func details(revision: Int, changes: [SVNChangedPath]) -> SVNRevisionDetails {
        SVNRevisionDetails(repositoryRootURL: URL(string: "https://example.test/repo")!,
            entry: SVNLogEntry(revision: revision, author: nil, date: nil, message: "fixture"), changes: changes)
    }

    private static func sharesStorage<T>(_ lhs: [T], _ rhs: [T]) -> Bool {
        lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { right in left.baseAddress == right.baseAddress }
        }
    }

    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !condition() {
            guard clock.now < deadline else { throw Failure(message: "timed out waiting for history model") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private struct Failure: Error { let message: String }
}

private actor DiffLoadCounter {
    var count = 0
    func load(path: String) -> String { count += 1; return path }
}
