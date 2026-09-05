import Foundation
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum WorkingCopyStatusRegressionChecks {
    static func run() throws {
        let snapshot = SvnDockRemoteStatusSnapshot(entries: [
            .init(relativePath: "remote-only.txt", status: .added),
            .init(relativePath: ".", status: .clean, propertiesChanged: true)
        ], checkedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try check(snapshot.entries.count == 2 && snapshot.entries.first?.propertiesChanged == true,
                  "a property-only root update and an incoming-only file both remain visible")

        var state = SvnDockRemoteStatusState(snapshot: snapshot)
        state.isChecking = true
        try check(state.showsPreviousResult && state.snapshot == snapshot,
                  "a repeated check labels the retained snapshot as the previous result")
        state.isChecking = false
        state.lastError = "The server is unavailable"
        try check(state.showsPreviousResult && state.snapshot?.checkedAt == snapshot.checkedAt,
                  "a failed check preserves the earlier result and its actual check time")
        state.lastError = nil
        state.isStale = true
        try check(state.showsPreviousResult,
                  "a working-copy mutation invalidates a previously successful server check")
        state.isStale = false
        try check(!state.showsPreviousResult,
                  "a fresh successful check can be presented without a stale-result marker")

        var copy = SvnDockWorkingCopy(name: "fixture", rootURL: URL(fileURLWithPath: "/fixture"))
        try check(copy.localStatusSummary != "本地：无修改",
                  "an unscanned working copy must not claim to have no local changes")
        copy.lastRefreshedAt = Date()
        copy.counts = .init(changed: 0, conflicts: 0, unversioned: 1)
        try check(copy.localStatusSummary != "本地：无修改",
                  "an unversioned file remains visible in an otherwise clean working-copy summary")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw WorkingCopyStatusRegressionFailure(message: message) }
    }
}

private struct WorkingCopyStatusRegressionFailure: Error { let message: String }
