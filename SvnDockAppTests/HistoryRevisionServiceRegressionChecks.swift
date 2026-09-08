import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum HistoryRevisionServiceRegressionChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    @discardableResult
    static func run() async throws -> Bool {
        guard let executable = SVNExecutableLocator.defaultCandidatePaths.map({ URL(fileURLWithPath: $0) })
            .first(where: {
                FileManager.default.isExecutableFile(atPath: $0.path)
                    && FileManager.default.isExecutableFile(atPath: $0.deletingLastPathComponent()
                        .appendingPathComponent("svnadmin").path)
            }) else {
            print("SKIP history revision integration: SVN and svnadmin are unavailable")
            return false
        }
        try await realCopiedDeletionCheck(executable: executable)
        return true
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    private static func realCopiedDeletionCheck(executable: URL) async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("history-copy-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repository = temporary.appendingPathComponent("repository")
        let root = temporary.appendingPathComponent("wc")
        let configuration = temporary.appendingPathComponent("svn-config")
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: false)
        try Data("[miscellany]\nenable-auto-props = no\nglobal-ignores =\n".utf8)
            .write(to: configuration.appendingPathComponent("config"))
        let runner = HistoryRevisionIsolatedRunner(configuration: configuration)
        let admin = executable.deletingLastPathComponent().appendingPathComponent("svnadmin")
        let created = try await ProcessRunner().run(ProcessInvocation(executableURL: admin, arguments: ["create", repository.path]))
        try check(created.succeeded, "copied deletion repository setup")
        func svn(_ arguments: [String], in directory: URL? = nil) async throws -> ProcessResult {
            let result = try await runner.run(ProcessInvocation(executableURL: executable,
                arguments: arguments, currentDirectoryURL: directory))
            try check(result.succeeded, "copied deletion fixture: \(result.standardErrorString)")
            return result
        }
        _ = try await svn(["checkout", repository.absoluteString, root.path])
        let copy = WorkingCopy(localPath: root)
        let builder = try SVNCommandBuilder(executableURL: executable)
        func run(_ operation: SVNOperationKind) async throws -> ProcessResult {
            let result = try await runner.run(builder.makeInvocation(for: operation, in: copy))
            try check(result.succeeded, "real copied deletion command: \(result.standardErrorString)")
            return result
        }
        func write(_ path: String, _ text: String) throws {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        try write("old/removed @ 文件.txt", "original copied content\n")
        try write("old/edited.txt", "before copy edit\n")
        try write("old/deleted-dir/child.txt", "directory child\n")
        try write("old/deleted-dir/nested/child @ 文件.txt", "nested directory child\n")
        try write("move.txt", "before move\n")
        try write("replacement.txt", "original replacement\n")
        try write("replaced-dir/old-only.txt", "old destination seed\n")
        try write("replaced-dir/old-only-dir/nested/child @ 文件.txt", "nested destination seed\n")
        try write("replacement-source/new.txt", "replacement source content\n")
        _ = try await svn(["add", "old", "move.txt", "replacement.txt", "replaced-dir", "replacement-source"], in: root)
        _ = try await svn(["propset", "custom:history", "old destination directory property", "replaced-dir/old-only-dir"], in: root)
        _ = try await svn(["propset", "custom:history", "copied directory property", "old/deleted-dir"], in: root)
        _ = try await run(.commit(paths: [], message: "Seed copied deletion history", keepLocks: false))
        try write("old/removed @ 文件.txt", "newer source content\n")
        try write("replaced-dir/old-only.txt", "old destination at r2\n")
        try write("replaced-dir/old-only-dir/nested/child @ 文件.txt", "nested destination at r2\n")
        _ = try await run(.commit(paths: [], message: "Advance source past copy revision", keepLocks: false))
        _ = try await run(.update(revision: nil))
        _ = try await svn(["copy", repository.appendingPathComponent("old").absoluteString + "@1", "new"], in: root)
        _ = try await svn(["delete", "new/removed @ 文件.txt@", "new/deleted-dir"], in: root)
        try write("new/edited.txt", "after copy edit\n")
        _ = try await svn(["move", "move.txt", "moved.txt"], in: root)
        try write("moved.txt", "after move\n")
        _ = try await svn(["delete", "replacement.txt"], in: root)
        try write("replacement.txt", "new replacement\n")
        _ = try await svn(["add", "replacement.txt"], in: root)
        _ = try await svn(["delete", "replaced-dir"], in: root)
        _ = try await svn(["copy", repository.appendingPathComponent("replacement-source").absoluteString + "@2", "replaced-dir"], in: root)
        _ = try await svn(["propset", "svn:ignore", "*.generated", "."], in: root)
        _ = try await run(.commit(paths: [], message: "Copy old revision and delete descendants", keepLocks: false))
        _ = try await svn(["delete", "new", "old", "replaced-dir", "replacement-source"], in: root)
        _ = try await run(.commit(paths: [], message: "Remove paths after historical revision", keepLocks: false))
        let log = try await run(.revisionLog(repositoryRoot: repository, revision: 3))
        let summaryResult = try await run(.revisionSummary(repositoryRoot: repository, revision: 3))
        let summary = try SVNXMLParser.parseDiffSummary(summaryResult.standardOutput)
        try check(!summary.contains { $0.url.contains("/new/removed") }, "real summary omits copied-then-deleted child")
        let shared = try FinderSharedStore(directoryURL: temporary.appendingPathComponent("app-state"))
        let service = try CoreSvnDockService(sharedStore: shared,
            executableLocator: SVNExecutableLocator(candidatePaths: [executable.path],
                environmentOverrideKey: "SVNDOCK_HISTORY_REVISION_TEST_UNUSED"), processRunner: runner)
        let uiCopy = SvnDockWorkingCopy(name: "history revision fixture", rootURL: root)
        let details = try await service.revisionDetails(revision: 3, in: uiCopy)
        let expectedPaths: Set<String> = ["/", "/new", "/new/edited.txt", "/new/removed @ 文件.txt",
            "/new/deleted-dir", "/new/deleted-dir/child.txt", "/new/deleted-dir/nested",
            "/new/deleted-dir/nested/child @ 文件.txt", "/moved.txt", "/replacement.txt", "/replaced-dir",
            "/replaced-dir/new.txt", "/replaced-dir/old-only.txt", "/replaced-dir/old-only-dir",
            "/replaced-dir/old-only-dir/nested", "/replaced-dir/old-only-dir/nested/child @ 文件.txt"]
        try check(Set(details.changes.map(\.path)) == expectedPaths, "production history details include every implicit deleted descendant")
        try check(await runner.copyDeletionSummaryCount == 1, "one source inventory expands the complete deleted subtree")
        let loggedPaths = try SVNXMLParser.parseLog(log.standardOutput)[0].changedPaths.map(\.path)
        try check(!loggedPaths.contains("/new/deleted-dir/child.txt"), "real verbose log omits implicit deleted descendants")
        let replacedDeletions: Set<String> = ["/replaced-dir/old-only.txt", "/replaced-dir/old-only-dir",
            "/replaced-dir/old-only-dir/nested", "/replaced-dir/old-only-dir/nested/child @ 文件.txt"]
        let summarizedDeletions = try Set(summary.filter { $0.action == .deleted }.map {
            try SVNRepositoryPath.path(for: $0.url, in: repository)
        })
        try check(replacedDeletions.isSubset(of: summarizedDeletions)
                  && replacedDeletions.isDisjoint(with: Set(loggedPaths)),
                  "replaced destination descendants occur only in the revision summary")
        for change in details.changes where replacedDeletions.contains(change.path) {
            try check(change.action == .deleted && !change.deletesCopySource
                      && change.copyFromPath == nil && change.copyFromRevision == nil,
                      "old destination deletions cannot inherit nonexistent replacement source nodes")
        }
        var outputs: [String: String] = [:]
        for change in details.changes {
            outputs[change.path] = try await service.revisionDiff(revision: 3, change: change,
                repositoryRoot: details.repositoryRootURL, in: uiCopy)
        }
        let deleted = details.changes.first { $0.path == "/new/removed @ 文件.txt" }
        try check(deleted?.deletesCopySource == true && deleted?.copyFromRevision == 1, "real deleted child retains old copy revision")
        try check(outputs["/new/removed @ 文件.txt"]?.contains("-original copied content") == true, "real copied deletion shows source content")
        try check(outputs["/new/removed @ 文件.txt"]?.contains("newer source content") == false, "real copied deletion does not use N-1 source content")
        try check(outputs["/new/deleted-dir"]?.contains("-copied directory property") == true, "copied deleted directory property preview")
        try check(outputs["/new/deleted-dir/child.txt"]?.contains("-directory child") == true, "production preview includes implicit deleted file contents")
        try check(outputs["/new/deleted-dir/nested/child @ 文件.txt"]?.contains("-nested directory child") == true, "production preview includes nested Unicode deletion contents")
        for change in details.changes where change.path.hasPrefix("/new/deleted-dir/") {
            try check(change.action == .deleted && change.copyFromRevision == 1,
                      "implicit descendant keeps deletion action and actual copied revision")
        }
        try check(outputs["/new/edited.txt"]?.contains("-before copy edit") == true && outputs["/new/edited.txt"]?.contains("+after copy edit") == true, "edited copied descendant retains source comparison")
        try check(outputs["/moved.txt"]?.contains("+after move") == true && outputs["/move.txt"] == nil, "move pairing and preview preserved")
        try check(outputs["/replacement.txt"]?.contains("-original replacement") == true && outputs["/replacement.txt"]?.contains("+new replacement") == true, "ordinary replacement preview preserved")
        try check(outputs["/replaced-dir/old-only.txt"]?.contains("-old destination at r2") == true,
                  "copied replacement deletion previews destination file at N-1")
        try check(outputs["/replaced-dir/old-only-dir/nested/child @ 文件.txt"]?.contains("-nested destination at r2") == true,
                  "copied replacement deletion previews nested destination file at N-1")
        try check(outputs["/replaced-dir/old-only-dir"]?.contains("-old destination directory property") == true,
                  "copied replacement deletion previews old destination directory properties")
        try check(outputs["/"]?.contains("svn:ignore") == true, "directory property-only preview preserved")
        print("History revision service checks passed: complete copied deletions, old copy revisions, source inventories, Unicode, deleted-at-HEAD paths, properties, moves and copied replacements")
    }

}

private actor HistoryRevisionIsolatedRunner: ProcessRunning {
    let configuration: URL
    private(set) var copyDeletionSummaryCount = 0
    init(configuration: URL) { self.configuration = configuration }

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        if invocation.arguments.contains("--summarize"),
           let newIndex = invocation.arguments.firstIndex(of: "--new"),
           invocation.arguments.indices.contains(newIndex + 1),
           invocation.arguments[newIndex + 1].hasSuffix("@0") {
            copyDeletionSummaryCount += 1
        }
        return try await ProcessRunner().run(ProcessInvocation(executableURL: invocation.executableURL,
            arguments: ["--config-dir", configuration.path, "--no-auth-cache"] + invocation.arguments,
            currentDirectoryURL: invocation.currentDirectoryURL, environment: invocation.environment,
            standardInput: invocation.standardInput,
            argumentFiles: invocation.argumentFiles.map {
                ProcessArgumentFile(argumentIndex: $0.argumentIndex + 3, contents: $0.contents)
            }))
    }
}
