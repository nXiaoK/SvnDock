import Foundation
import SvnDockCore

enum SelectedCommitRegressionChecks {
    /// Returns false only when the host has no usable SVN + svnadmin pair.
    @discardableResult
    static func run() async throws -> Bool {
        guard let executable = ["/opt/homebrew/bin/svn", "/usr/local/bin/svn", "/usr/bin/svn"]
            .map({ URL(fileURLWithPath: $0) }).first(where: {
                FileManager.default.isExecutableFile(atPath: $0.path)
                    && FileManager.default.isExecutableFile(atPath: $0.deletingLastPathComponent()
                        .appendingPathComponent("svnadmin").path)
            }) else {
            print("SKIP selected commit integration: SVN and svnadmin are unavailable")
            return false
        }
        let fixture = try SelectedCommitFixture(executable: executable)
        defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        try await fixture.create()
        try await directoryPropertiesExcludeChildEdits(fixture)
        try await addedDirectoryKeepsExplicitChildSelection(fixture)
        try await missingAddedParentRejectsWholeCommit(fixture)
        try await copiedDirectoryPreservesHistoryAndLocalEdits(fixture)
        try await directoryDeletionKeepsTreeSemantics(fixture)
        try await staleAndConflictedSelectionsDoNotCommit(fixture)
        print("Selected commit integration passed: properties, added parents, copies, deletion trees, stale selections and conflicts")
        return true
    }

    private static func directoryPropertiesExcludeChildEdits(_ fixture: SelectedCommitFixture) async throws {
        try fixture.write("unselected edit\n", to: "properties/child.txt")
        _ = try await fixture.svn(["propset", "svn:ignore", "*.cache", "properties"])
        try await fixture.commit(["properties"], message: "Commit only directory properties")
        try check(try await fixture.cat("properties/child.txt") == "base\n",
                  "directory property commit must preserve the server child content")
        let status = try await fixture.status()
        try check(status.contains { $0.path == "properties/child.txt" && $0.status == .modified },
                  "unselected child modification remains local after the directory property commit")
        try check(try await fixture.latestLog().changedPaths.map(\.path) == ["/properties"],
                  "the revision changes only the selected directory")
    }

    private static func addedDirectoryKeepsExplicitChildSelection(_ fixture: SelectedCommitFixture) async throws {
        try fixture.write("selected\n", to: "new tree/selected.txt")
        try fixture.write("not selected\n", to: "new tree/remaining.txt")
        _ = try await fixture.svn(["add", "--", "new tree"])
        try await fixture.commit(["new tree", "new tree/selected.txt"], message: "Commit selected added child")
        let files = try await fixture.svn(["list", fixture.remote("new tree").absoluteString])
        try check(files.standardOutputString == "selected.txt\n", "unselected added sibling is absent from the repository")
        let status = try await fixture.status()
        try check(status.contains { $0.path == "new tree/remaining.txt" && $0.status == .added },
                  "unselected added sibling remains scheduled locally")
    }

    private static func missingAddedParentRejectsWholeCommit(_ fixture: SelectedCommitFixture) async throws {
        try fixture.write("pending\n", to: "pending-parent/child.txt")
        _ = try await fixture.svn(["add", "--", "pending-parent"])
        let before = try await fixture.repositoryRevision()
        do {
            // Mix in an otherwise valid target to verify all-or-nothing preflight.
            try await fixture.commit(["pending-parent/child.txt", "properties/child.txt"], message: "Must reject missing parent")
            throw SelectedCommitFailure(message: "missing added parent must reject the entire selection")
        } catch SVNSelectedCommitError.missingParent(let parent) {
            try check(parent == "pending-parent", "missing-parent error identifies the actual dependency")
        }
        try check(try await fixture.repositoryRevision() == before, "rejected parent dependency creates no revision")
        try check(try await fixture.cat("properties/child.txt") == "base\n", "valid mixed target is not partially committed")
    }

    private static func copiedDirectoryPreservesHistoryAndLocalEdits(_ fixture: SelectedCommitFixture) async throws {
        _ = try await fixture.svn(["copy", "--", "source", "copied"])
        try fixture.write("local copied edit\n", to: "copied/child.txt")
        try await fixture.commit(["copied"], message: "Commit copied directory with history")
        let log = try await fixture.latestLog()
        let copy = log.changedPaths.first { $0.path == "/copied" }
        try check(copy?.copyFromPath == "/source" && copy?.copyFromRevision == 1,
                  "directory copy retains its repository source and source revision")
        try check(try await fixture.cat("copied/child.txt") == "base\n", "copy commits source content, excluding unselected local edits")
        let status = try await fixture.status()
        try check(status.contains { $0.path == "copied/child.txt" && $0.status == .modified },
                  "unselected copied-child modification remains available for a later commit")
    }

    private static func directoryDeletionKeepsTreeSemantics(_ fixture: SelectedCommitFixture) async throws {
        _ = try await fixture.svn(["delete", "--", "remove-tree"])
        try await fixture.commit(["remove-tree"], message: "Delete complete directory tree")
        let listing = try await fixture.svn(["list", "--recursive", fixture.repository.absoluteString])
        try check(!listing.standardOutputString.split(separator: "\n").contains { $0.hasPrefix("remove-tree/") },
                  "selected directory deletion removes every server descendant")
        let log = try await fixture.latestLog()
        try check(log.changedPaths.contains { $0.path == "/remove-tree" && $0.action == .deleted },
                  "history records the selected directory deletion")
    }

    private static func staleAndConflictedSelectionsDoNotCommit(_ fixture: SelectedCommitFixture) async throws {
        try fixture.write("temporary edit\n", to: "stale.txt")
        _ = try await fixture.svn(["revert", "--", "stale.txt"])
        var before = try await fixture.repositoryRevision()
        do {
            try await fixture.commit(["stale.txt"], message: "Must reject stale selection")
            throw SelectedCommitFailure(message: "a file reverted since selection must be rejected")
        } catch SVNSelectedCommitError.changedSelection(let path) {
            try check(path == "stale.txt", "stale-selection error identifies the obsolete path")
        }
        try check(try await fixture.repositoryRevision() == before, "stale selection creates no revision")

        let peer = fixture.temporary.appendingPathComponent("peer", isDirectory: true)
        _ = try await fixture.svn(["checkout", fixture.repository.absoluteString, peer.path])
        try Data("server edit\n".utf8).write(to: peer.appendingPathComponent("conflict.txt"))
        _ = try await fixture.svn(["commit", "-m", "Advance conflicting file", "--", "conflict.txt"], in: peer)
        try fixture.write("local edit\n", to: "conflict.txt")
        before = try await fixture.repositoryRevision()
        do {
            try await fixture.commit(["conflict.txt"], message: "Must reject out-of-date file")
            throw SelectedCommitFailure(message: "an out-of-date modified file must not be committed")
        } catch SVNSelectedCommitError.commandFailed { }
        try check(try await fixture.repositoryRevision() == before, "out-of-date failure creates no revision")
        _ = try await fixture.svn(["update", "--accept", "postpone", "--", "conflict.txt"])
        let status = try await fixture.status()
        try check(status.contains { $0.path == "conflict.txt" && $0.status == .conflicted },
                  "fixture update creates a real text conflict")
        do {
            try await fixture.commit(["conflict.txt"], message: "Must reject unresolved conflict")
            throw SelectedCommitFailure(message: "conflicted selection must be rejected before writing")
        } catch SVNSelectedCommitError.changedSelection(let path) {
            try check(path == "conflict.txt", "conflict rejection identifies the conflicted path")
        }
        try check(try await fixture.repositoryRevision() == before, "conflicted selection creates no revision")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw SelectedCommitFailure(message: message) }
    }
}

private struct SelectedCommitFailure: Error { let message: String }

private struct SelectedCommitFixture: Sendable {
    let temporary: URL
    let repository: URL
    let workingCopy: WorkingCopy
    let executable: URL
    let runner: SelectedCommitIsolatedRunner

    init(executable: URL) throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("svndock-selected-commit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        self.temporary = temporary
        repository = temporary.appendingPathComponent("repository", isDirectory: true)
        workingCopy = WorkingCopy(localPath: temporary.appendingPathComponent("wc", isDirectory: true))
        self.executable = executable
        runner = SelectedCommitIsolatedRunner(configuration: temporary.appendingPathComponent("svn-config", isDirectory: true))
    }

    func create() async throws {
        let result = try await ProcessRunner().run(ProcessInvocation(
            executableURL: executable.deletingLastPathComponent().appendingPathComponent("svnadmin"),
            arguments: ["create", repository.path]
        ))
        guard result.succeeded else { throw SelectedCommitFailure(message: "temporary repository creation failed: \(result.standardErrorString)") }
        _ = try await svn(["checkout", repository.absoluteString, workingCopy.localPath.path], in: temporary)
        for path in ["properties/child.txt", "source/child.txt", "remove-tree/nested/child.txt", "stale.txt", "conflict.txt"] {
            try write("base\n", to: path)
        }
        _ = try await svn(["add", "--", "properties", "source", "remove-tree", "stale.txt", "conflict.txt"])
        _ = try await svn(["commit", "-m", "Seed selected commit fixture", "--", "."])
    }

    func write(_ text: String, to relativePath: String) throws {
        let file = workingCopy.localPath.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func remote(_ relativePath: String) -> URL { repository.appendingPathComponent(relativePath) }

    func commit(_ paths: [String], message: String) async throws {
        try await SVNSelectedCommit(executableURL: executable, runner: runner)
            .run(targets: paths, message: message, in: workingCopy)
    }

    func svn(_ arguments: [String], in directory: URL? = nil) async throws -> ProcessResult {
        let result = try await runner.run(ProcessInvocation(
            executableURL: executable, arguments: arguments,
            currentDirectoryURL: directory ?? workingCopy.localPath
        ))
        guard result.succeeded else { throw SelectedCommitFailure(message: "fixture SVN command failed: \(result.standardErrorString)") }
        return result
    }

    func cat(_ relativePath: String) async throws -> String {
        try await svn(["cat", remote(relativePath).absoluteString]).standardOutputString
    }

    func repositoryRevision() async throws -> String {
        try await svn(["info", "--show-item", "revision", repository.absoluteString]).standardOutputString
    }

    func latestLog() async throws -> SVNLogEntry {
        let result = try await svn(["log", "--xml", "--verbose", "--limit", "1", repository.absoluteString])
        guard let log = try SVNXMLParser.parseLog(result.standardOutput).first else {
            throw SelectedCommitFailure(message: "missing latest fixture revision")
        }
        return log
    }

    func status() async throws -> [StatusEntry] {
        let result = try await svn(["status", "--xml"])
        return try SVNXMLParser.parseStatus(result.standardOutput, workingCopyURL: workingCopy.localPath)
    }
}

/// Keep SVN configuration files inside the disposable test directory, including
/// invocations built by the production selected-commit implementation.
private struct SelectedCommitIsolatedRunner: ProcessRunning {
    let configuration: URL

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        try await ProcessRunner().run(ProcessInvocation(
            executableURL: invocation.executableURL,
            arguments: ["--config-dir", configuration.path, "--no-auth-cache", "--non-interactive"] + invocation.arguments,
            currentDirectoryURL: invocation.currentDirectoryURL,
            environment: invocation.environment,
            standardInput: invocation.standardInput,
            argumentFiles: invocation.argumentFiles.map {
                ProcessArgumentFile(argumentIndex: $0.argumentIndex + 4, contents: $0.contents)
            }
        ))
    }
}
