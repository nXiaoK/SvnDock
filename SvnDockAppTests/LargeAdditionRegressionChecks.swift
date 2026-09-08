import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum LargeAdditionRegressionChecks {
    @discardableResult
    static func run() async throws -> Bool {
        try commandBoundaries()
        guard let executable = SVNExecutableLocator.defaultCandidatePaths
            .map({ URL(fileURLWithPath: $0) }).first(where: {
                FileManager.default.isExecutableFile(atPath: $0.path)
                    && FileManager.default.isExecutableFile(
                        atPath: $0.deletingLastPathComponent().appendingPathComponent("svnadmin").path
                    )
            }) else {
            print("SKIP large addition integration: SVN and svnadmin are unavailable")
            return false
        }
        try await realSVNAddition(executable: executable)
        print("Large addition regression passed: bounded targets, UTF-8 byte limits, literal special names, selection scope and complete boundary validation")
        return true
    }

    private static func commandBoundaries() throws {
        let builder = try SVNCommandBuilder(executableURL: URL(fileURLWithPath: "/usr/bin/svn"))
        let copy = WorkingCopy(localPath: URL(fileURLWithPath: "/tmp/SvnDock-large-add", isDirectory: true))
        func invocation(_ paths: [String]) throws -> ProcessInvocation {
            try builder.makeInvocation(for: .add(paths: paths, parents: true, force: true, depth: .infinity), in: copy)
        }
        let small = try invocation(["-option", "测试 space@x.txt", "line\nbreak.txt"])
        try check(small.argumentFiles.isEmpty
                    && Array(small.arguments.suffix(4)) == ["--", "-option", "测试 space@x.txt@", "line\nbreak.txt"],
                  "small additions retain literal argv and peg escaping")
        try check(try invocation((0..<1_000).map { "file-\($0)" }).argumentFiles.isEmpty,
                  "1,000 short targets retain argv")
        try check(try invocation((0..<1_001).map { "file-\($0)" }).argumentFiles.count == 1,
                  "more than 1,000 targets use a file")
        let exactLimit = (0..<500).map { String(repeating: "x", count: 123) + String(format: "%04d", $0) }
        try check(exactLimit.reduce(0) { $0 + $1.utf8.count + 1 } == 64_000,
                  "byte-limit fixture reaches exactly 64,000 bytes")
        try check(try invocation(exactLimit).argumentFiles.isEmpty, "64,000 bytes retain argv")
        try check(try invocation(exactLimit + ["x"]).argumentFiles.count == 1,
                  "more than 64,000 bytes use a file")
        let unicode = (0..<400).map { String(repeating: "长", count: 60) + String($0) }
        try check(unicode.joined().count < 64_000 && (try invocation(unicode)).argumentFiles.count == 1,
                  "byte threshold counts UTF-8 bytes rather than characters")
        let paths = (0..<4_100).map { "file-\($0).txt" }
            + ["-option", "测试 space@x.txt", "line\nbreak.txt", "carriage\rreturn.txt"]
        let large = try invocation(paths)
        try check(Array(large.arguments.prefix(6)) == ["add", "--force", "--parents", "--depth", "infinity", "--non-interactive"],
                  "large additions preserve force, parent and depth options")
        try check(large.arguments.count < 15 && large.argumentFiles.count == 1,
                  "large additions keep process arguments bounded")
        try check(large.argumentFiles.first?.contents == Data(
            (paths.dropLast(2).map { "./" + $0 + ($0.contains("@") ? "@" : "") }.joined(separator: "\n") + "\n").utf8
        ), "targets files preserve every selected regular path")
        try check(Array(large.arguments.suffix(3)) == ["--", "line\nbreak.txt", "carriage\rreturn.txt"],
                  "CR and LF filenames remain literal argv instead of injecting targets")
    }

    private static func realSVNAddition(executable: URL) async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("svndock-large-add-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repository = temporary.appendingPathComponent("repository", isDirectory: true)
        let root = temporary.appendingPathComponent("wc", isDirectory: true)
        let runner = LargeAdditionRunner(configuration: temporary.appendingPathComponent("svn-config"))
        let created = try await ProcessRunner().run(ProcessInvocation(
            executableURL: executable.deletingLastPathComponent().appendingPathComponent("svnadmin"),
            arguments: ["create", repository.path]
        ))
        try check(created.succeeded, "create disposable large-add repository")
        func svn(_ arguments: [String], directory: URL? = nil) async throws -> ProcessResult {
            let result = try await runner.run(ProcessInvocation(
                executableURL: executable, arguments: arguments, currentDirectoryURL: directory ?? root,
                environment: ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
            ))
            try check(result.succeeded, "large-add fixture SVN failed: \(result.standardErrorString)")
            return result
        }
        func status() async throws -> [StatusEntry] {
            let result = try await svn(["status", "--xml", "--", "."])
            return try SVNXMLParser.parseStatus(result.standardOutput, workingCopyURL: root, resolveNodeKinds: false)
        }
        _ = try await svn(["checkout", repository.absoluteString, root.path], directory: temporary)
        let selected = (0..<4_100).map { "file-\($0).txt" }
            + ["space name.txt", "测试@example.txt", "-option.txt"]
        let controlNames = ["line\nbreak.txt", "carriage\rreturn.txt"]
        let unselected = ["unselected.txt", "line", "break.txt", "carriage", "return.txt"]
        let longPaths = (0..<400).map { String(repeating: "长", count: 60) + "-\($0).txt" }
        let contents = Data("selected content stays on disk\n".utf8)
        for path in selected + unselected + longPaths + controlNames {
            try contents.write(to: root.appendingPathComponent(path))
        }
        let outside = temporary.appendingPathComponent("outside.txt")
        try contents.write(to: outside)
        let shared = try FinderSharedStore(directoryURL: temporary.appendingPathComponent("shared"))
        let service = try CoreSvnDockService(
            sharedStore: shared,
            executableLocator: SVNExecutableLocator(candidatePaths: [executable.path],
                                                     environmentOverrideKey: "SVNDOCK_LARGE_ADD_TEST_UNUSED"),
            processRunner: runner
        )
        let copy = SvnDockWorkingCopy(name: "Large addition fixture", rootURL: root)
        for outsidePath in ["../outside.txt", outside.path] {
            do {
                try await service.add(relativePaths: selected + [outsidePath], in: copy)
                throw LargeAdditionFailure(message: "outside targets must reject the whole addition")
            } catch SVNCommandBuilderError.pathOutsideWorkingCopy { }
        }
        try check(await runner.additions.isEmpty, "invalid mixed selections must not launch an add process")
        try check(try await status().allSatisfy { $0.status != .added },
                  "boundary rejection must leave all valid targets unversioned")

        try await service.add(relativePaths: selected, in: copy)
        let firstStatus = try await status()
        try check(Set(firstStatus.filter { $0.status == .added }.map(\.path)) == Set(selected),
                  "a 4,103-target addition schedules exactly the selected files")
        try check(firstStatus.filter { unselected.contains($0.path) }.allSatisfy { $0.status == .unversioned },
                  "unselected and newline-split lookalikes stay unversioned")
        let firstInvocations = await runner.additions
        try check(firstInvocations.count == 1 && firstInvocations[0].arguments.count < 15
                    && firstInvocations[0].argumentFiles.count == 1,
                  "production add executes the large selection once with bounded arguments")
        try check(longPaths.count < 1_000 && longPaths.reduce(0) { $0 + $1.utf8.count + 1 } > 64_000,
                  "long-path integration independently exceeds the byte threshold")
        try await service.add(relativePaths: longPaths, in: copy)
        let invocations = await runner.additions
        try check(invocations.count == 2 && invocations[1].argumentFiles.count == 1 && invocations[1].arguments.count < 15,
                  "production add uses a targets file for fewer than 1,000 long UTF-8 names")
        // SVN rejects control characters in repository paths. Keep them
        // literal so SVN reports the actual unsupported name instead of
        // interpreting separate lines as additional selected files.
        for name in controlNames {
            do {
                try await service.add(relativePaths: selected + [name], in: copy)
                throw LargeAdditionFailure(message: "SVN must reject unsupported control-character paths")
            } catch {
                try check(error.localizedDescription.contains("E160005"),
                          "literal control-character paths must reach SVN's path validation")
            }
            let additions = await runner.additions
            try check(additions.last?.argumentFiles.count == 1
                        && additions.last.map { Array($0.arguments.suffix(2)) } == ["--", name],
                      "production add passes CR/LF paths literally alongside the targets file")
        }
        let finalStatus = try await status()
        try check(Set(finalStatus.filter { $0.status == .added }.map(\.path)) == Set(selected + longPaths),
                  "both additions preserve the complete selection without adding other files")
        try check(Set(finalStatus.filter { $0.status == .unversioned }.map(\.path)) == Set(unselected + controlNames),
                  "rejected CR/LF paths cannot inject newline-split lookalike targets")
        for path in selected + unselected + longPaths + controlNames {
            try check(try Data(contentsOf: root.appendingPathComponent(path)) == contents,
                      "addition preserves local content: \(path)")
        }
        try check(try Data(contentsOf: outside) == contents, "boundary rejection preserves the outside file")
        let info = try await svn(["info", "--xml", repository.absoluteString])
        try check(try SVNXMLParser.parseInfo(info.standardOutput).revision == 0,
                  "adding files never commits a repository revision")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw LargeAdditionFailure(message: message) }
    }
}

private struct LargeAdditionFailure: Error { let message: String }

private actor LargeAdditionRunner: ProcessRunning {
    let configuration: URL
    private(set) var additions: [ProcessInvocation] = []

    init(configuration: URL) { self.configuration = configuration }

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        if invocation.arguments.first == "add" { additions.append(invocation) }
        return try await ProcessRunner().run(ProcessInvocation(
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
