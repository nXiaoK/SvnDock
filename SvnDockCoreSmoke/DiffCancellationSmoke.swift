#if SVNDOCK_SMOKE_TESTS
import Foundation
import SvnDockCore

enum DiffCancellationSmoke {
    static func run() async throws {
        let firstHunk = "--- file.txt\n+++ file.txt\n@@ -1 +1 @@\n-before\n+after\n"
        let deletion = "@@ -10,20000 +10,0 @@\n" + String(repeating: "-deleted\n", count: 20_000)
        let patch = firstHunk + deletion
        let complete = UnifiedDiffParser.parse(patch)
        try check(complete.hunks.count == 2 && complete.hunks[1].rows.count == 20_000,
                  "large deletion remains complete when parsing is not cancelled")

        // Cancel this task from within its own body, so the check does not
        // depend on thread scheduling or a machine-specific parsing duration.
        let cancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return UnifiedDiffParser.parse(patch)
        }.value
        try check(cancelled.hunks.isEmpty && cancelled.fallbackText == patch,
                  "cancelled parsing must retain the complete original output without publishing partial hunks")

        let metadata = String(repeating: "SVN metadata without text hunks\n", count: 20_000)
        let cancelledMetadata = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return UnifiedDiffParser.parse(metadata)
        }.value
        try check(cancelledMetadata.hunks.isEmpty && cancelledMetadata.fallbackText == metadata,
                  "cancelled metadata parsing retains its original output")
        print("Diff cancellation smoke tests passed")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    private struct Failure: Error { let message: String }
}
#endif
