import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum LocalDifferenceRegressionChecks {
    @discardableResult
    static func run() async throws -> Bool {
        try commandBoundaries()
        try await outputBounds()
        guard let executable = SVNExecutableLocator.defaultCandidatePaths.map({ URL(fileURLWithPath: $0) })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path)
                && FileManager.default.isExecutableFile(atPath: $0.deletingLastPathComponent().appendingPathComponent("svnadmin").path) }) else {
            print("SKIP local difference integration: SVN and svnadmin are unavailable")
            return false
        }
        try await realSVN(executable: executable)
        print("Local difference regression passed: EOL/whitespace classification, meaningful and unknown changes preserved, real SVN status/content untouched, bounded process output")
        return true
    }

    private static func commandBoundaries() throws {
        let builder = try SVNCommandBuilder(executableURL: URL(fileURLWithPath: "/usr/bin/svn"))
        let copy = WorkingCopy(localPath: URL(fileURLWithPath: "/tmp/SvnDock-local-difference"))
        for ignoreWhitespace in [false, true] {
            let operation = SVNOperationKind.localDifference(relativePath: "-中文@name.txt", ignoringWhitespace: ignoreWhitespace)
            let invocation = try builder.makeInvocation(for: operation, in: copy)
            try check(!operation.mutatesWorkingCopy && Array(invocation.arguments.suffix(2)) == ["--", "-中文@name.txt"],
                      "classification remains read-only and retains literal diff filenames")
            try check(invocation.arguments.contains("--internal-diff") && invocation.arguments.contains("empty")
                        && !invocation.arguments.contains("--ignore-properties"), "classification keeps internal file/property diff semantics")
        }
        do {
            _ = try builder.makeInvocation(for: .localDifference(relativePath: "../outside", ignoringWhitespace: true), in: copy)
            throw LocalDifferenceFailure(message: "outside paths must be rejected")
        } catch SVNCommandBuilderError.pathOutsideWorkingCopy { }
    }

    private static func outputBounds() async throws {
        let runner = ProcessRunner()
        func output(_ stdout: Int, _ stderr: Int, limit: Int?) async throws -> ProcessResult {
            try await runner.run(ProcessInvocation(executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-c", "import sys; sys.stdout.write('x'*\(stdout)); sys.stderr.write('y'*\(stderr))"],
                outputByteLimit: limit))
        }
        let exact = try await output(4_096, 4_096, limit: 4_096)
        try check(exact.succeeded && exact.standardOutput.count == 4_096 && exact.standardError.count == 4_096,
                  "each stream accepts exactly its output bound")
        for counts in [(1_000_000, 1_000_000), (0, 4_097), (4_097, 0)] {
            do {
                _ = try await output(counts.0, counts.1, limit: 4_096)
                throw LocalDifferenceFailure(message: "oversized streams must never return partial success")
            } catch ProcessRunnerError.outputLimitExceeded(4_096) { }
        }
        try check(try await output(8_192, 8_192, limit: nil).standardOutput.count == 8_192,
                  "existing unbounded invocations preserve their full output")
        let task = Task {
            try await runner.run(ProcessInvocation(executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-c", "import sys,time\nwhile True:\n sys.stdout.write('x'*10000); sys.stdout.flush(); time.sleep(.01)"],
                outputByteLimit: 4_096))
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            throw LocalDifferenceFailure(message: "bounded output must retain process cancellation")
        } catch is CancellationError { }
    }

    private static func realSVN(executable: URL) async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("svndock-local-difference-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repository = temporary.appendingPathComponent("repo")
        let root = temporary.appendingPathComponent("wc")
        let runner = LocalDifferenceRunner(configuration: temporary.appendingPathComponent("config"))
        let created = try await ProcessRunner().run(ProcessInvocation(
            executableURL: executable.deletingLastPathComponent().appendingPathComponent("svnadmin"),
            arguments: ["create", repository.path]))
        try check(created.succeeded, "create isolated SVN repository")
        func svn(_ arguments: [String], directory: URL? = nil) async throws -> ProcessResult {
            let result = try await runner.run(ProcessInvocation(executableURL: executable, arguments: arguments,
                currentDirectoryURL: directory ?? root, environment: ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]))
            try check(result.succeeded, "fixture SVN failed: \(result.standardErrorString)")
            return result
        }
        _ = try await svn(["checkout", repository.absoluteString, root.path], directory: temporary)
        let baseline = "let value = 1;\n中文 content\n"
        let edits: [(String, Data, SVNLocalDifferenceKind)] = [
            ("crlf.txt", Data(baseline.replacingOccurrences(of: "\n", with: "\r\n").utf8), .lineEndingsOnly),
            ("cr.txt", Data(baseline.replacingOccurrences(of: "\n", with: "\r").utf8), .lineEndingsOnly),
            ("mixed.txt", Data("let value = 1;\r\n中文 content\n".utf8), .lineEndingsOnly),
            ("tabs.txt", Data("let\tvalue = 1;\n中文 content\n".utf8), .whitespaceOnly),
            ("trailing.txt", Data("let value = 1; \t\n中文 content  \n".utf8), .whitespaceOnly),
            ("internal.txt", Data("letvalue = 1;\n中文 content\n".utf8), .whitespaceOnly),
            ("content.txt", Data("let value = 2;\n中文 content\n".utf8), .substantive),
            ("blank-line.txt", Data((baseline + "\n").utf8), .substantive),
            ("no-final-newline.txt", Data(baseline.dropLast().utf8), .substantive),
            ("bom.txt", Data([0xef, 0xbb, 0xbf]) + Data(baseline.utf8), .substantive),
            ("unicode-space.txt", Data("let\u{00a0}value = 1;\n中文 content\n".utf8), .substantive),
            ("二@三.txt", Data(baseline.replacingOccurrences(of: "\n", with: "\r\n").utf8), .lineEndingsOnly),
            ("-option.txt", Data(("  " + baseline).utf8), .whitespaceOnly),
            ("invalid-utf8.txt", Data([0xff, 0xfe, 0x00, 0x20]), .unknown),
            ("large.txt", Data(repeating: 32, count: 2 * 1_024 * 1_024 + 1), .unknown)
        ]
        let extra = ["properties.txt", "both.txt", "binary.txt", "race.txt", "unchanged.txt", "deleted.txt", "conflict.txt"]
        for name in edits.map(\.0) + extra { try Data(baseline.utf8).write(to: root.appendingPathComponent(name)) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory"), withIntermediateDirectories: false)
        _ = try await svn(["add", "--force", "--", "."])
        _ = try await svn(["propset", "svn:mime-type", "application/octet-stream", "--", "binary.txt"])
        _ = try await svn(["commit", "-m", "baseline"])
        for (name, data, _) in edits { try data.write(to: root.appendingPathComponent(name)) }
        for name in ["both.txt", "binary.txt", "race.txt"] {
            try Data(baseline.replacingOccurrences(of: "\n", with: "\r\n").utf8).write(to: root.appendingPathComponent(name))
        }
        _ = try await svn(["propset", "custom", "changed", "--", "properties.txt", "both.txt", "directory"])
        _ = try await svn(["copy", "--", "unchanged.txt", "copy.txt"])
        try Data(baseline.replacingOccurrences(of: "\n", with: "\r\n").utf8).write(to: root.appendingPathComponent("copy.txt"))
        try Data(baseline.utf8).write(to: root.appendingPathComponent("added.txt"))
        _ = try await svn(["add", "--", "added.txt"])
        _ = try await svn(["delete", "--", "deleted.txt"])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("symlink.txt"), withDestinationURL: root.appendingPathComponent("crlf.txt"))
        let other = temporary.appendingPathComponent("other")
        _ = try await svn(["checkout", repository.absoluteString, other.path], directory: temporary)
        try Data("remote\n".utf8).write(to: other.appendingPathComponent("conflict.txt"))
        _ = try await svn(["commit", "-m", "remote edit"], directory: other)
        try Data("local\n".utf8).write(to: root.appendingPathComponent("conflict.txt"))
        _ = try await svn(["update", "--", "conflict.txt"])
        let service = try CoreSvnDockService(sharedStore: FinderSharedStore(directoryURL: temporary.appendingPathComponent("shared")),
            executableLocator: SVNExecutableLocator(candidatePaths: [executable.path], environmentOverrideKey: "SVNDOCK_DIFFERENCE_TEST_UNUSED"),
            processRunner: runner)
        let copy = SvnDockWorkingCopy(name: "Classification fixture", rootURL: root)
        let beforeStatus = try await svn(["status", "--xml", "--", "."])
        let initialInvocations = await runner.invocations.count
        for (name, _, expected) in edits {
            let actual = try await service.classifyLocalDifference(relativePath: name, in: copy)
            try check(actual == expected, "\(name): expected \(expected), got \(actual)")
        }
        for name in ["properties.txt", "both.txt", "binary.txt", "directory", "added.txt", "copy.txt", "unchanged.txt", "conflict.txt", "symlink.txt", "deleted.txt"] {
            do {
                let classification = try await service.classifyLocalDifference(relativePath: name, in: copy)
                try check(classification == .substantive || classification == .unknown, "\(name) must remain visible")
            } catch is LocalDifferenceFailure { throw LocalDifferenceFailure(message: "\(name) was hidden") }
            catch { /* Unreadable/deleted/symlink paths also remain visible. */ }
        }
        let classificationInvocations = Array(await runner.invocations.dropFirst(initialInvocations))
        try check(classificationInvocations.allSatisfy { ["status", "info", "diff"].contains($0.arguments.first ?? "") },
                  "classification must only issue read-only local SVN commands")
        try check(classificationInvocations.allSatisfy { $0.outputByteLimit == 8 * 1_024 * 1_024 },
                  "every classification command uses a hard per-stream memory bound")
        let afterStatus = try await svn(["status", "--xml", "--", "."])
        try check(try SVNXMLParser.parseStatus(beforeStatus.standardOutput, workingCopyURL: root, resolveNodeKinds: false)
                    == SVNXMLParser.parseStatus(afterStatus.standardOutput, workingCopyURL: root, resolveNodeKinds: false),
                  "filtering leaves SVN status unchanged")
        for (name, data, _) in edits { try check(try Data(contentsOf: root.appendingPathComponent(name)) == data, "filtering preserves \(name)") }
        await runner.overrideDiff(with: ProcessResult(terminationStatus: 0, terminationReason: .exit,
                                                       standardOutput: Data(), standardError: Data()))
        try check(try await service.classifyLocalDifference(relativePath: "crlf.txt", in: copy) == .unknown,
                  "empty original diff cannot be relabeled as a known EOL edit")
        await runner.overrideDiff(with: ProcessResult(terminationStatus: 0, terminationReason: .exit,
                                                       standardOutput: Data(), standardError: Data("warning".utf8)))
        try check(try await service.classifyLocalDifference(relativePath: "crlf.txt", in: copy) == .unknown,
                  "successful diff with diagnostics remains unverified")
        await runner.overrideDiff(with: nil)
        await runner.rewriteAfterNextDiff(root.appendingPathComponent("race.txt"))
        try check(try await service.classifyLocalDifference(relativePath: "race.txt", in: copy) == .unknown,
                  "a concurrent content change must invalidate hidden classification")
        do {
            _ = try await service.classifyLocalDifference(relativePath: "../outside.txt", in: copy)
            throw LocalDifferenceFailure(message: "service must reject outside paths")
        } catch SVNCommandBuilderError.pathOutsideWorkingCopy { }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw LocalDifferenceFailure(message: message) }
    }
}

private struct LocalDifferenceFailure: Error { let message: String }

private actor LocalDifferenceRunner: ProcessRunning {
    let configuration: URL
    private(set) var invocations: [ProcessInvocation] = []
    private var rewrite: URL?
    private var diffOverride: ProcessResult?
    init(configuration: URL) { self.configuration = configuration }
    func rewriteAfterNextDiff(_ file: URL) { rewrite = file }
    func overrideDiff(with result: ProcessResult?) { diffOverride = result }
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        invocations.append(invocation)
        if invocation.arguments.first == "diff", let diffOverride { return diffOverride }
        let result = try await ProcessRunner().run(ProcessInvocation(executableURL: invocation.executableURL,
            arguments: ["--config-dir", configuration.path, "--no-auth-cache", "--non-interactive"] + invocation.arguments,
            currentDirectoryURL: invocation.currentDirectoryURL, environment: invocation.environment,
            standardInput: invocation.standardInput,
            argumentFiles: invocation.argumentFiles.map { ProcessArgumentFile(argumentIndex: $0.argumentIndex + 4, contents: $0.contents) },
            outputByteLimit: invocation.outputByteLimit))
        if invocation.arguments.first == "diff", let file = rewrite {
            rewrite = nil
            try Data("changed while classifying\n".utf8).write(to: file)
        }
        return result
    }
}
