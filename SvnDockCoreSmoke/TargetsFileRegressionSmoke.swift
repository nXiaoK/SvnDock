#if SVNDOCK_SMOKE_TESTS
import Foundation
import SvnDockCore

enum TargetsFileRegressionSmoke {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func run() async throws {
        let builder = try SVNCommandBuilder(executableURL: URL(fileURLWithPath: "/usr/bin/true"))
        let copy = WorkingCopy(localPath: FileManager.default.temporaryDirectory)
        let ordinary = (0..<1_000).map { "file-\($0).txt" }
        let literal = ["report ", "report\t", "report\u{0b}", "report\u{0c}", "line\nbreak", "carriage\rreturn"]
        let paths = ordinary + [" leading space", "tab\tinside", "peg@ "] + literal
        let expectedFile = Data(((ordinary + [" leading space", "tab\tinside", "peg@ @"])
            .map { "./" + $0 }.joined(separator: "\n") + "\n").utf8)
        for operation in [
            SVNOperationKind.commit(paths: paths, message: "exact targets", keepLocks: false),
            .infoTargets(paths: paths),
            .add(paths: paths, parents: false, force: false, depth: nil),
            .delete(paths: paths),
            .revert(paths: paths, depth: .empty)
        ] {
            let invocation = try builder.makeInvocation(for: operation, in: copy)
            try check(invocation.argumentFiles.map(\.contents) == [expectedFile], "targets files must preserve exact filenames")
            try check(Array(invocation.arguments.suffix(literal.count + 1)) == ["--"] + literal,
                      "SVN must receive line breaks and trailing whitespace as literal arguments")
        }
        let whitespaceOnly = try builder.makeInvocation(
            for: .commit(paths: [" ", "\t"], message: "whitespace names", keepLocks: false), in: copy)
        try check(whitespaceOnly.argumentFiles.isEmpty && Array(whitespaceOnly.arguments.suffix(3)) == ["--", " ", "\t"],
                  "literal-only selections must not generate empty targets files")

        // Literal fallback retains ProcessRunner's pre-launch argument limits.
        // /usr/bin/true would succeed if either guard accidentally stopped firing.
        for oversizedPaths in [
            (0..<4_096).map { "file-\($0) " },
            (0..<2_048).map { String(repeating: "x", count: 700) + "\($0) " }
        ] {
            do {
                _ = try await ProcessRunner().run(builder.makeInvocation(
                    for: .revert(paths: oversizedPaths, depth: .empty), in: copy))
                throw Failure(description: "oversized literal selection was launched")
            } catch ProcessRunnerError.invalidInvocation { }
        }

        if ProcessInfo.processInfo.environment["SVNDOCK_TARGETS_INTEGRATION"] == "1" {
            try await realWorkingCopyCheck()
        }
        print("Targets file checks passed: exact whitespace, peg escaping, all targets-file commands and pre-launch argument limits")
    }

    private static func realWorkingCopyCheck() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("svndock-targets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let runner = ProcessRunner()
        let executable = try SVNExecutableLocator().locate()
        let admin = executable.deletingLastPathComponent().appendingPathComponent("svnadmin")
        let repository = temporary.appendingPathComponent("repository")
        let root = temporary.appendingPathComponent("wc")
        for invocation in [
            ProcessInvocation(executableURL: admin, arguments: ["create", repository.path]),
            ProcessInvocation(executableURL: executable, arguments: ["checkout", repository.absoluteString, root.path])
        ] {
            let result = try await runner.run(invocation)
            try check(result.succeeded, "targets fixture setup: \(result.standardErrorString)")
        }
        let copy = WorkingCopy(localPath: root)
        let builder = try SVNCommandBuilder(executableURL: executable)
        func run(_ operation: SVNOperationKind) async throws -> ProcessResult {
            let result = try await runner.run(builder.makeInvocation(for: operation, in: copy))
            try check(result.succeeded, "targets integration command: \(result.standardErrorString)")
            return result
        }
        let selected = (0..<1_000).map { "file-\($0).txt" } + ["report ", "peg@ "]
        let original = Data("original\n".utf8)
        let edited = Data("local edit\n".utf8)
        for path in selected + ["report"] { try original.write(to: root.appendingPathComponent(path)) }
        _ = try await run(.add(paths: ["."], parents: false, force: true, depth: .infinity))
        _ = try await run(.commit(paths: ["."], message: "Seed exact target fixture", keepLocks: false))
        for path in selected + ["report"] { try edited.write(to: root.appendingPathComponent(path)) }

        _ = try await run(.revert(paths: selected, depth: .empty))
        let sibling = try Data(contentsOf: root.appendingPathComponent("report"))
        try check(sibling == edited, "bulk revert must preserve the unselected trimmed-name sibling")
        for path in selected {
            let content = try Data(contentsOf: root.appendingPathComponent(path))
            try check(content == original, "bulk revert must restore every intended target: \(path)")
        }

        let info = try await run(.infoTargets(paths: ["report ", "peg@ "]))
        let infos = try SVNXMLParser.parseInfos(info.standardOutput)
        try check(Set(infos.map(\.path)) == ["report ", "peg@ "], "batched info must inspect exact names")
        try edited.write(to: root.appendingPathComponent("report "))
        _ = try await run(.commit(paths: ["report "], message: "Commit exact trailing-space target", keepLocks: false, depth: .empty))
        let status = try await run(.status(SVNStatusOptions()))
        let entries = try SVNXMLParser.parseStatus(status.standardOutput)
        try check(entries.count == 1 && entries[0].path == "report" && entries[0].status == .modified,
                  "commit must leave the unselected sibling modified and the selected whitespace filename clean")
        print("Real SVN targets checks passed: 1,002-target revert preserves unselected sibling, exact info and single-file commit")
    }
}
#endif
