import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum HistoryPageServiceRegressionChecks {
    @discardableResult
    static func run() async throws -> Bool {
        try commandRangesAndValidation()
        let legacy = MockSvnDockService()
        let placeholder = SvnDockWorkingCopy(name: "history", rootURL: URL(fileURLWithPath: "/tmp/history-placeholder"))
        let first = try await legacy.historyPage(for: placeholder, relativePaths: [], limit: 2, beforeRevision: nil)
        try check(first.count == 2, "legacy service still supplies the first history page")
        do {
            _ = try await legacy.historyPage(for: placeholder, relativePaths: [], limit: 2, beforeRevision: 4)
            throw HistoryPageServiceFailure(message: "legacy pagination must not silently reread HEAD")
        } catch SvnDockServiceError.unavailable { }
        guard let executable = SVNExecutableLocator.defaultCandidatePaths.map({ URL(fileURLWithPath: $0) })
            .first(where: {
                FileManager.default.isExecutableFile(atPath: $0.path)
                    && FileManager.default.isExecutableFile(atPath: $0.deletingLastPathComponent()
                        .appendingPathComponent("svnadmin").path)
            }) else {
            print("SKIP history paging integration: SVN and svnadmin are unavailable")
            return false
        }
        try await realHistoryPages(executable: executable)
        print("History page service checks passed: exclusive ranges, sparse revisions, new commits, copied ancestry and literal paths")
        return true
    }

    private static func commandRangesAndValidation() throws {
        let copy = WorkingCopy(localPath: URL(fileURLWithPath: "/tmp/svndock-history-command"))
        let builder = try SVNCommandBuilder(executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/svn"))
        let initial = try builder.makeInvocation(for: .log(paths: [], limit: 101), in: copy)
        try check(initial.arguments.contains("HEAD:1") && initial.arguments.contains("101"),
                  "first page explicitly reads from HEAD with the requested probe count")
        let oldOperation = try JSONDecoder().decode(
            SVNOperationKind.self, from: Data(#"{"log":{"paths":[],"limit":25}}"#.utf8)
        )
        try check(oldOperation == .log(paths: [], limit: 25),
                  "previously encoded log operations decode without a cursor")
        let older = try builder.makeInvocation(for: .log(paths: ["变更/user@example.txt"], limit: 101, beforeRevision: 23), in: copy)
        try check(older.arguments.contains("22:1") && !older.arguments.contains("HEAD:1")
                  && older.arguments.last == "变更/user@example.txt@",
                  "older page uses the exclusive cursor and keeps literal local peg escaping")
        let largest = try builder.makeInvocation(for: .log(paths: [], limit: 1, beforeRevision: Int.max), in: copy)
        try check(largest.arguments.contains("\(Int.max - 1):1"), "largest cursor does not overflow")
        for cursor in [-1, Int.min] {
            do {
                _ = try builder.makeInvocation(for: .log(paths: [], limit: 1, beforeRevision: cursor), in: copy)
                throw HistoryPageServiceFailure(message: "negative log cursor must fail before subtraction")
            } catch SVNCommandBuilderError.invalidRevision(let value) {
                try check(value == cursor, "invalid cursor error retains the rejected value")
            }
        }
        for cursor in [0, 1] {
            do {
                _ = try builder.makeInvocation(for: .log(paths: [], limit: 1, beforeRevision: cursor), in: copy)
                throw HistoryPageServiceFailure(message: "empty page must not become an ascending SVN range")
            } catch SVNCommandBuilderError.invalidArgument { }
        }
        for limit in [0, -1, 10_001, Int.max] {
            do {
                _ = try builder.makeInvocation(for: .log(paths: [], limit: limit, beforeRevision: 10), in: copy)
                throw HistoryPageServiceFailure(message: "invalid page size must fail")
            } catch SVNCommandBuilderError.invalidLogLimit { }
        }
        for path in ["../outside", "/tmp/outside-history-copy"] {
            do {
                _ = try builder.makeInvocation(for: .log(paths: [path], limit: 2, beforeRevision: 10), in: copy)
                throw HistoryPageServiceFailure(message: "outside history target must fail")
            } catch SVNCommandBuilderError.pathOutsideWorkingCopy { }
        }
        do {
            _ = try builder.makeInvocation(for: .log(paths: ["invalid\0path"], limit: 2, beforeRevision: 10), in: copy)
            throw HistoryPageServiceFailure(message: "NUL history target must fail")
        } catch SVNCommandBuilderError.invalidArgument { }
    }

    private static func realHistoryPages(executable: URL) async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("svndock-history-pages-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repository = temporary.appendingPathComponent("repository", isDirectory: true)
        let root = temporary.appendingPathComponent("wc", isDirectory: true)
        let runner = HistoryPageServiceRunner(configuration: temporary.appendingPathComponent("svn-config", isDirectory: true))
        let adminResult = try await ProcessRunner().run(ProcessInvocation(
            executableURL: executable.deletingLastPathComponent().appendingPathComponent("svnadmin"),
            arguments: ["create", repository.path]
        ))
        try check(adminResult.succeeded, "create disposable history repository")
        func svn(_ arguments: [String], directory: URL? = nil) async throws {
            let result = try await runner.run(ProcessInvocation(
                executableURL: executable, arguments: arguments,
                currentDirectoryURL: directory ?? root
            ))
            try check(result.succeeded, "history fixture SVN failed: \(result.standardErrorString)")
        }
        try await svn(["checkout", repository.absoluteString, root.path], directory: temporary)
        let selectedPath = "变更@example.txt"
        let selectedFile = root.appendingPathComponent(selectedPath)
        let unrelatedFile = root.appendingPathComponent("unrelated.txt")
        try Data("seed\n".utf8).write(to: selectedFile)
        try Data("seed\n".utf8).write(to: unrelatedFile)
        try await svn(["add", "--", selectedPath + "@", "unrelated.txt"])
        try await svn(["commit", "-m", "Seed paging fixture", "--", "."])
        for revision in 2...7 {
            let file = revision.isMultiple(of: 2) ? unrelatedFile : selectedFile
            try Data("revision \(revision)\n".utf8).write(to: file)
            try await svn(["commit", "-m", "Fixture revision \(revision)", "--", file.lastPathComponent + "@"])
        }
        let shared = try FinderSharedStore(directoryURL: temporary.appendingPathComponent("app-state", isDirectory: true))
        let service = try CoreSvnDockService(
            sharedStore: shared,
            executableLocator: SVNExecutableLocator(candidatePaths: [executable.path], environmentOverrideKey: "SVNDOCK_HISTORY_TEST_UNUSED"),
            processRunner: runner
        )
        let copy = SvnDockWorkingCopy(name: "history fixture", rootURL: root)
        let first = try await service.historyPage(for: copy, relativePaths: [selectedPath], limit: 2, beforeRevision: nil)
        try check(first.map(\.revision) == [7, 5], "first path page spans sparse repository revisions")
        try Data("revision 8 while paging\n".utf8).write(to: selectedFile)
        try await svn(["commit", "-m", "New commit between pages", "--", selectedPath + "@"])
        let older = try await service.historyPage(for: copy, relativePaths: [selectedPath], limit: 2, beforeRevision: 5)
        try check(older.map(\.revision) == [3, 1], "new commits cannot shift or duplicate an older page")
        try check(Set((first + older).map(\.revision)).count == 4, "combined pages contain no duplicate revision")
        let ranges = await runner.logRanges
        try check(ranges == ["HEAD:1", "4:1"], "second page queries only the remaining old revision range")
        for cursor in [0, 1] {
            let end = try await service.historyPage(for: copy, relativePaths: [selectedPath], limit: 101, beforeRevision: cursor)
            try check(end.isEmpty, "revision one terminates history without a repository query")
        }
        try check(await runner.logRanges == ranges, "empty pages launch no log invocation")
        do {
            _ = try await service.historyPage(for: copy, relativePaths: [selectedPath], limit: 0, beforeRevision: 1)
            throw HistoryPageServiceFailure(message: "empty page still validates page size")
        } catch SVNCommandBuilderError.invalidLogLimit { }
        do {
            _ = try await service.historyPage(for: copy, relativePaths: ["../outside"], limit: 2, beforeRevision: 1)
            throw HistoryPageServiceFailure(message: "empty page still validates paths")
        } catch SVNCommandBuilderError.pathOutsideWorkingCopy { }
        do {
            _ = try await service.historyPage(for: copy, relativePaths: [], limit: 2, beforeRevision: Int.min)
            throw HistoryPageServiceFailure(message: "service rejects negative cursors safely")
        } catch SVNCommandBuilderError.invalidRevision { }
        let copiedPath = "复制@history.txt"
        try await svn(["copy", "--", selectedPath + "@", copiedPath + "@"])
        try await svn(["commit", "-m", "Copy path with ancestry", "--", copiedPath + "@"])
        let copiedFirst = try await service.historyPage(for: copy, relativePaths: [copiedPath], limit: 2, beforeRevision: nil)
        let copiedOlder = try await service.historyPage(for: copy, relativePaths: [copiedPath], limit: 2, beforeRevision: 8)
        try check(copiedFirst.map(\.revision) == [9, 8] && copiedOlder.map(\.revision) == [7, 5],
                  "paging a literal copied path follows its source history across the copy revision")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw HistoryPageServiceFailure(message: message) }
    }
}

private struct HistoryPageServiceFailure: Error { let message: String }

private actor HistoryPageServiceRunner: ProcessRunning {
    let configuration: URL
    private(set) var logRanges: [String] = []
    init(configuration: URL) { self.configuration = configuration }
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        if invocation.arguments.first == "log",
           let revisionFlag = invocation.arguments.firstIndex(of: "--revision"),
           invocation.arguments.indices.contains(revisionFlag + 1) {
            logRanges.append(invocation.arguments[revisionFlag + 1])
        }
        return try await ProcessRunner().run(ProcessInvocation(
            executableURL: invocation.executableURL,
            arguments: ["--config-dir", configuration.path, "--no-auth-cache", "--non-interactive"] + invocation.arguments,
            currentDirectoryURL: invocation.currentDirectoryURL,
            environment: invocation.environment,
            standardInput: invocation.standardInput,
            argumentFiles: invocation.argumentFiles.map { ProcessArgumentFile(argumentIndex: $0.argumentIndex + 4, contents: $0.contents) }
        ))
    }
}
