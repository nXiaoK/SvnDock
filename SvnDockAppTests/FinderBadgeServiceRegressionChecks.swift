import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum FinderBadgeServiceRegressionChecks {
    @discardableResult
    static func run() async throws -> Bool {
        guard let executable = SVNExecutableLocator.defaultCandidatePaths.map({ URL(fileURLWithPath: $0) })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path)
                && FileManager.default.isExecutableFile(atPath: $0.deletingLastPathComponent().appendingPathComponent("svnadmin").path) }) else {
            print("SKIP Finder badge backend integration: SVN and svnadmin unavailable")
            return false
        }
        let fixture = try FinderBadgeFixture(executable: executable)
        defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        try await fixture.create()
        let cleanPath = "src/clean@文本.txt"
        let clean = try await fixture.service.finderTarget(relativePath: cleanPath, in: fixture.copy)
        try check(clean.entry.status == .clean && clean.entry.relativePath == cleanPath
                    && clean.repositoryRelativePath == "/trunk/" + cleanPath,
                  "an explicit clean Unicode/@ target retains its repository-root-relative path")

        try fixture.write("local modified\n", to: "src/modified.txt")
        try fixture.write("local conflict\n", to: "src/deep/conflict.txt")
        try fixture.write("opaque sentinel\n", to: "cache/nested/sentinel.txt")
        try fixture.write("unversioned sentinel\n", to: "loose/nested/sentinel.txt")
        let peer = fixture.temporary.appendingPathComponent("peer")
        _ = try await fixture.svn(["checkout", fixture.trunkURL.absoluteString, peer.path], at: fixture.temporary)
        try Data("remote conflict\n".utf8).write(to: peer.appendingPathComponent("src/deep/conflict.txt"))
        _ = try await fixture.svn(["commit", "-m", "Create a remote conflict", "--", "."], at: peer)
        _ = try await fixture.svn(["update", "--accept", "postpone", "--", "."])

        let foreign = fixture.copy.rootURL.appendingPathComponent("foreign")
        _ = try await fixture.svn(["checkout", fixture.trunkURL.absoluteString, foreign.path], at: fixture.temporary)
        let linked = fixture.copy.rootURL.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: fixture.copy.rootURL.appendingPathComponent("src"))
        let escaped = fixture.copy.rootURL.appendingPathComponent("escaped")
        try FileManager.default.createSymbolicLink(at: escaped, withDestinationURL: fixture.temporary)
        for path in ["cache", "loose", "foreign/src/clean@文本.txt", "linked/clean@文本.txt", "escaped", "../peer"] {
            try await expectRejected {
                _ = try await fixture.service.finderTarget(relativePath: path, in: fixture.copy)
            }
        }

        let statusCount = await fixture.runner.invocations.count
        try await fixture.service.refreshFinderBadges(for: fixture.copy, directoryPaths: [
            fixture.copy.rootURL.path, fixture.copy.rootURL.appendingPathComponent("src").path,
            fixture.copy.rootURL.appendingPathComponent("cache").path,
            fixture.copy.rootURL.appendingPathComponent("loose/nested").path,
            foreign.appendingPathComponent("src").path, linked.path
        ], preferredPaths: [fixture.copy.rootURL.appendingPathComponent(cleanPath).path])
        let snapshot = try await fixture.shared.loadBadgeSnapshot()
        let root = fixture.copy.rootURL.path
        try check(snapshot.directEntries?[root + "/" + cleanPath] == .clean
                    && snapshot.directEntries?[root + "/src/modified.txt"] == .modified,
                  "visible normal and modified nodes receive separate precise states")
        try check(snapshot.entries[root] == .conflicted
                    && snapshot.entries[root + "/src"] == .conflicted
                    && snapshot.entries[root + "/src/deep"] == .conflicted
                    && snapshot.directEntries?[root + "/src"] == .clean,
                  "deep conflict summaries reach all ancestors without changing their exact status")
        try check(snapshot.directEntries?[root + "/cache"] == .ignored
                    && snapshot.directEntries?[root + "/loose"] == .unversioned
                    && snapshot.entries[root + "/cache/nested/sentinel.txt"] == nil
                    && snapshot.entries[root + "/loose/nested/sentinel.txt"] == nil
                    && snapshot.entries[root + "/foreign/src/clean@文本.txt"] == nil,
                  "ignored, unversioned and foreign directories stay opaque")
        try check(snapshot.perRootUpdatedAt?[root] != nil, "a completed Finder refresh records this root's time")
        let invocations = await fixture.runner.invocations.dropFirst(statusCount)
        for invocation in invocations where invocation.arguments.first == "status" && invocation.arguments.contains("--verbose") {
            try check(invocation.arguments.contains("immediates")
                        && !invocation.arguments.contains("cache")
                        && !invocation.arguments.contains("loose/nested")
                        && !invocation.arguments.contains("foreign/src")
                        && !invocation.arguments.contains("linked"),
                      "verbose status only visits authoritative versioned observation directories")
        }
        let local = try await fixture.service.status(for: fixture.copy)
        try check(!local.entries.contains { $0.relativePath == cleanPath || $0.status == .ignored },
                  "Finder green and ignored rows never inflate the App local change list")
        let sparse = try await fixture.shared.loadBadgeSnapshot()
        try check(sparse.directEntries?[root + "/" + cleanPath] == nil,
                  "an ordinary sparse refresh conservatively drops cached green nodes")
        try check(try String(contentsOf: fixture.copy.rootURL.appendingPathComponent("cache/nested/sentinel.txt"), encoding: .utf8) == "opaque sentinel\n",
                  "Finder observation never mutates ignored contents")
        print("Finder badge backend integration passed: real clean/modified/conflict states, ancestor summaries, opaque directories, foreign/symlink rejection and explicit Unicode paths")
        return true
    }

    private static func expectRejected(_ operation: () async throws -> Void) async throws {
        do { try await operation() } catch { return }
        throw FinderBadgeServiceFailure(message: "expected an unversioned or unsafe Finder target to be rejected")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw FinderBadgeServiceFailure(message: message) }
    }
}

private struct FinderBadgeServiceFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct FinderBadgeFixture: Sendable {
    let temporary: URL
    let repository: URL
    let trunkURL: URL
    let copy: SvnDockWorkingCopy
    let executable: URL
    let runner: FinderBadgeIsolatedRunner
    let shared: FinderSharedStore
    let service: CoreSvnDockService

    init(executable: URL) throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("svndock-finder-badge-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        repository = temporary.appendingPathComponent("repository")
        trunkURL = repository.appendingPathComponent("trunk")
        copy = SvnDockWorkingCopy(name: "Finder backend fixture", rootURL: temporary.appendingPathComponent("wc"))
        self.executable = executable
        let configuration = temporary.appendingPathComponent("svn-config")
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: false)
        try Data("[miscellany]\nglobal-ignores =\n".utf8).write(to: configuration.appendingPathComponent("config"))
        runner = FinderBadgeIsolatedRunner(configuration: configuration)
        shared = try FinderSharedStore(directoryURL: temporary.appendingPathComponent("app-state"))
        service = try CoreSvnDockService(sharedStore: shared,
            executableLocator: SVNExecutableLocator(candidatePaths: [executable.path], environmentOverrideKey: "SVNDOCK_FINDER_BADGE_TEST_UNUSED"),
            processRunner: runner)
    }

    func create() async throws {
        let created = try await ProcessRunner().run(ProcessInvocation(executableURL: executable.deletingLastPathComponent().appendingPathComponent("svnadmin"),
            arguments: ["create", repository.path]))
        guard created.succeeded else { throw FinderBadgeServiceFailure(message: "temporary repository creation failed") }
        _ = try await svn(["mkdir", trunkURL.absoluteString, "-m", "Create trunk"], at: temporary)
        _ = try await svn(["checkout", trunkURL.absoluteString, copy.rootURL.path], at: temporary)
        _ = try await shared.register(WorkingCopy(id: copy.id, localPath: copy.rootURL))
        for path in ["src/clean@文本.txt", "src/modified.txt", "src/deep/conflict.txt"] {
            try write("initial content\n", to: path)
        }
        _ = try await svn(["add", "--", "src"])
        _ = try await svn(["propset", "svn:ignore", "cache\n", "--", "."])
        _ = try await svn(["commit", "-m", "Seed Finder fixture", "--", "."])
    }

    func write(_ content: String, to path: String) throws {
        let url = copy.rootURL.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    func svn(_ arguments: [String], at directory: URL? = nil) async throws -> ProcessResult {
        let result = try await runner.run(ProcessInvocation(executableURL: executable, arguments: arguments,
            currentDirectoryURL: directory ?? copy.rootURL))
        guard result.succeeded else { throw FinderBadgeServiceFailure(message: "fixture SVN failed: \(result.standardErrorString)") }
        return result
    }
}

private actor FinderBadgeIsolatedRunner: ProcessRunning {
    private let configuration: URL
    private let runner = ProcessRunner()
    private(set) var invocations: [ProcessInvocation] = []

    init(configuration: URL) { self.configuration = configuration }

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        invocations.append(invocation)
        var arguments = invocation.arguments
        arguments.insert(contentsOf: ["--config-dir", configuration.path], at: 1)
        let argumentFiles = invocation.argumentFiles.map {
            ProcessArgumentFile(argumentIndex: $0.argumentIndex >= 1 ? $0.argumentIndex + 2 : $0.argumentIndex,
                contents: $0.contents)
        }
        return try await runner.run(ProcessInvocation(executableURL: invocation.executableURL, arguments: arguments,
            currentDirectoryURL: invocation.currentDirectoryURL, environment: invocation.environment,
            standardInput: invocation.standardInput, argumentFiles: argumentFiles))
    }
}
