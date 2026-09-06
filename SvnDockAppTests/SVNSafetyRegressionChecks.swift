import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum SVNSafetyRegressionChecks {
    static func run() async throws {
        try await additionUndoPreservesContent()
        try await switchedTargetsCannotSilentlyCommit()
        print("SVN safety checks passed")
    }

    private static func switchedTargetsCannotSilentlyCommit() async throws {
        let f = try await SafetyFixture.create()
        defer { f.remove() }
        _ = try await f.svn(["copy", f.remote("trunk"), f.remote("branches/release"), "-m", "Create branch"])
        let service = try f.service()
        let reviewed = try await service.registerWorkingCopy(at: f.root)
        _ = try await f.svn(["switch", f.remote("branches/release/source"), "source"])
        try f.write("switched edit\n", to: "source/a.txt")
        try f.write("ordinary edit\n", to: "other.txt")
        let snapshot = try await service.status(for: reviewed)
        try check(snapshot.entries.first { $0.relativePath == "source/a.txt" }?.switchedAncestorPath == "source",
                  "a clean switched ancestor remains visible on its modified descendants")
        let revision = try await f.revision()
        do {
            try await service.commit(workingCopy: reviewed, relativePaths: ["source/a.txt", "other.txt"], message: "Must reject switched subtree")
            throw SafetyFailure("switched subtree unexpectedly committed")
        } catch SVNSelectedCommitError.switchedTarget { }
        try check(try await f.revision() == revision, "switched rejection must preserve the whole transaction")
        try check(try f.read("source/a.txt") == "switched edit\n", "rejected commit preserves local edits")

        _ = try await f.svn(["switch", f.remote("trunk/source"), "source"])
        _ = try await f.svn(["switch", f.remote("branches/release"), "."])
        let refreshed = try await service.refreshWorkingCopyMetadata(for: reviewed)
        try check(refreshed.repositoryURL != reviewed.repositoryURL, "fixture really switched the WC root")
        do {
            // The service cache now knows the new branch; it must not replace
            // the identity that the caller actually reviewed.
            try await service.commit(workingCopy: reviewed, relativePaths: ["other.txt"], message: "Must reject changed identity")
            throw SafetyFailure("stale reviewed repository unexpectedly committed")
        } catch SVNSelectedCommitError.repositoryIdentityChanged { }
        try check(try await f.revision() == revision, "root identity rejection creates no revision")
        try await service.commit(workingCopy: refreshed, relativePaths: ["other.txt"], message: "Commit newly reviewed branch")
        try check(try await f.svn(["cat", f.remote("branches/release/other.txt")]).standardOutputString == "ordinary edit\n",
                  "a freshly reviewed root branch remains usable")
        try check(try await f.svn(["cat", f.remote("trunk/other.txt")]).standardOutputString == "base other\n",
                  "the rejected stale review never changes trunk")
    }

    private static func additionUndoPreservesContent() async throws {
        let f = try await SafetyFixture.create()
        defer { f.remove() }
        let service = try f.service()
        let copy = try await service.registerWorkingCopy(at: f.root)
        try f.write("ordinary addition\n", to: "ordinary/file.txt")
        _ = try await f.svn(["add", "ordinary"])
        _ = try await f.svn(["copy", "source", "copied"])
        try f.write("unique copied edit\n", to: "copied/a.txt")
        try f.write("private data\n", to: "copied/private.txt")
        try f.write("ignored data\n", to: "copied/cache.bin")
        _ = try await f.svn(["propset", "svn:ignore", "cache.bin", "copied"])
        try f.write("scheduled new file\n", to: "copied/new.txt")
        _ = try await f.svn(["add", "copied/new.txt"])
        let before = try await f.status()
        do {
            try await service.unscheduleAdd(relativePaths: ["ordinary", "copied"], in: copy)
            throw SafetyFailure("copy undo unexpectedly succeeded")
        } catch SVNAdditionUndoError.copiedAddition { }
        try check(try await f.status() == before,
                  "a mixed selection must preserve every SVN schedule/property before rejecting a copy")
        for (path, text) in ["copied/a.txt": "unique copied edit\n", "copied/private.txt": "private data\n",
                             "copied/cache.bin": "ignored data\n", "copied/new.txt": "scheduled new file\n"] {
            try check(try f.read(path) == text, "copy undo must preserve \(path)")
        }
        try await service.unscheduleAdd(relativePaths: ["ordinary"], in: copy)
        try check(try f.read("ordinary/file.txt") == "ordinary addition\n", "ordinary additions retain disk content")

        try f.write("pre-move edit\n", to: "source/a.txt")
        _ = try await f.svn(["move", "source", "moved"])
        let movedStatus = try await f.status()
        do {
            try await service.unscheduleAdd(relativePaths: ["moved"], in: copy)
            throw SafetyFailure("move undo unexpectedly succeeded")
        } catch SVNAdditionUndoError.copiedAddition { }
        try check(try f.read("moved/a.txt") == "pre-move edit\n", "move destination preserves unique content")
        try check(try await f.status() == movedStatus, "move relationships remain intact")

        try f.write("parent content\n", to: "parent/plain.txt")
        _ = try await f.svn(["add", "parent"])
        _ = try await f.svn(["copy", "copied", "parent/nested"])
        do {
            try await service.unscheduleAdd(relativePaths: ["parent"], in: copy)
            throw SafetyFailure("nested copied addition unexpectedly accepted")
        } catch SVNAdditionUndoError.copiedAddition { }
        try check(try f.read("parent/nested/a.txt") == "unique copied edit\n", "collapsed parent cannot hide a copied child")
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw SafetyFailure(message) }
    }
}

private struct SafetyFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct SafetyFixture: Sendable {
    let directory: URL
    let repository: URL
    let root: URL
    let executable: URL
    let runner: SafetyRunner

    static func create() async throws -> Self {
        let executable = try SVNExecutableLocator().locate()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("svndock-safety-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let fixture = Self(directory: directory, repository: directory.appendingPathComponent("repo", isDirectory: true),
                           root: directory.appendingPathComponent("wc", isDirectory: true), executable: executable,
                           runner: SafetyRunner(configuration: directory.appendingPathComponent("config", isDirectory: true)))
        do {
            let result = try await ProcessRunner().run(ProcessInvocation(
                executableURL: executable.deletingLastPathComponent().appendingPathComponent("svnadmin"),
                arguments: ["create", fixture.repository.path]))
            try SVNSafetyRegressionChecks.check(result.succeeded, "cannot create disposable SVN repository")
            _ = try await fixture.svn(["mkdir", fixture.remote("trunk"), fixture.remote("branches"), "-m", "Create fixture layout"], in: directory)
            _ = try await fixture.svn(["checkout", fixture.remote("trunk"), fixture.root.path], in: directory)
            try fixture.write("base\n", to: "source/a.txt")
            try fixture.write("base sibling\n", to: "source/b.txt")
            try fixture.write("base other\n", to: "other.txt")
            _ = try await fixture.svn(["add", "source", "other.txt"])
            _ = try await fixture.svn(["commit", "-m", "Seed fixture", "."])
            return fixture
        } catch {
            fixture.remove()
            throw error
        }
    }

    func service(runner override: (any ProcessRunning)? = nil) throws -> CoreSvnDockService {
        try CoreSvnDockService(sharedStore: FinderSharedStore(directoryURL: directory.appendingPathComponent("shared")),
                              executableLocator: SVNExecutableLocator(candidatePaths: [executable.path]),
                              processRunner: override ?? runner)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
    func remote(_ path: String) -> String { repository.appendingPathComponent(path).absoluteString }
    func write(_ text: String, to path: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    func read(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
    func status() async throws -> Set<StatusEntry> {
        let result = try await svn(["status", "--xml", "--no-ignore"])
        return Set(try SVNXMLParser.parseStatus(result.standardOutput, workingCopyURL: root, resolveNodeKinds: false))
    }
    func revision() async throws -> String {
        try await svn(["info", "--show-item", "revision", repository.absoluteString]).standardOutputString
    }
    func svn(_ arguments: [String], in cwd: URL? = nil) async throws -> ProcessResult {
        let result = try await runner.run(ProcessInvocation(executableURL: executable, arguments: arguments,
                                                            currentDirectoryURL: cwd ?? root))
        try SVNSafetyRegressionChecks.check(result.succeeded, "fixture SVN failure: \(result.standardErrorString)")
        return result
    }
}

private struct SafetyRunner: ProcessRunning {
    let configuration: URL
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        try await ProcessRunner().run(ProcessInvocation(executableURL: invocation.executableURL,
            arguments: ["--config-dir", configuration.path, "--non-interactive", "--no-auth-cache"] + invocation.arguments,
            currentDirectoryURL: invocation.currentDirectoryURL, environment: invocation.environment,
            standardInput: invocation.standardInput, argumentFiles: invocation.argumentFiles.map {
                ProcessArgumentFile(argumentIndex: $0.argumentIndex + 4, contents: $0.contents)
            }))
    }
}
