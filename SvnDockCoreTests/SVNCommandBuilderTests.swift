import Foundation
import XCTest
@testable import SvnDockCore

final class SVNCommandBuilderTests: XCTestCase {
    private let executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/svn")
    private let rootURL = URL(fileURLWithPath: "/tmp/SvnDockTests/WorkingCopy", isDirectory: true)

    func testStatusBuildsXMLCommandWithoutShell() throws {
        let builder = try SVNCommandBuilder(executableURL: executableURL)
        let workingCopy = WorkingCopy(localPath: rootURL)
        let invocation = try builder.makeInvocation(
            for: .status(SVNStatusOptions(showRemoteUpdates: true, includeIgnored: true)),
            in: workingCopy
        )

        XCTAssertEqual(invocation.executableURL, executableURL)
        XCTAssertEqual(invocation.currentDirectoryURL, rootURL)
        XCTAssertEqual(
            invocation.arguments,
            [
                "status", "--xml", "--show-updates", "--no-ignore",
                "--non-interactive", "--", "."
            ]
        )
    }

    func testStatusCanBeScopedToSafePaths() throws {
        let builder = try SVNCommandBuilder(executableURL: executableURL)
        let workingCopy = WorkingCopy(localPath: rootURL)
        let invocation = try builder.makeInvocation(
            for: .status(SVNStatusOptions(
                includeIgnored: true,
                paths: ["Sources/user@example.swift"]
            )),
            in: workingCopy
        )

        XCTAssertEqual(
            invocation.arguments,
            [
                "status", "--xml", "--no-ignore", "--non-interactive",
                "--", "Sources/user@example.swift@"
            ]
        )
    }

    func testStatusCanLimitDirectoryTraversalDepth() throws {
        let builder = try SVNCommandBuilder(executableURL: executableURL)
        let invocation = try builder.makeInvocation(
            for: .status(SVNStatusOptions(depth: .immediates, paths: ["ImportedProject"])),
            in: WorkingCopy(localPath: rootURL)
        )

        XCTAssertEqual(
            invocation.arguments,
            [
                "status", "--xml", "--depth", "immediates", "--non-interactive",
                "--", "ImportedProject"
            ]
        )
    }

    func testStatusOptionsDecodeLegacyPayloadWithoutDepth() throws {
        let legacyPayload = Data(
            #"{"showRemoteUpdates":false,"includeIgnored":true,"paths":["Sources"]}"#.utf8
        )

        let options = try JSONDecoder().decode(SVNStatusOptions.self, from: legacyPayload)

        XCTAssertNil(options.depth)
        XCTAssertEqual(options.paths, ["Sources"])
        let encoded = try JSONEncoder().encode(options)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["depth"])
    }

    func testFilenameBeginningWithDashComesAfterOptionTerminator() throws {
        let builder = try SVNCommandBuilder(executableURL: executableURL)
        let invocation = try builder.makeInvocation(
            for: .add(
                paths: ["-not-an-option.txt"],
                parents: false,
                force: false,
                depth: nil
            ),
            in: WorkingCopy(localPath: rootURL)
        )

        XCTAssertEqual(Array(invocation.arguments.suffix(2)), ["--", "-not-an-option.txt"])
    }

    func testAtSignFilenameGetsEmptyPegRevision() throws {
        let builder = try SVNCommandBuilder(executableURL: executableURL)
        let invocation = try builder.makeInvocation(
            for: .add(
                paths: ["notes/user@example.txt"],
                parents: false,
                force: false,
                depth: nil
            ),
            in: WorkingCopy(localPath: rootURL)
        )

        XCTAssertEqual(invocation.arguments.last, "notes/user@example.txt@")
    }

    func testAddSupportsForcedRecursiveDirectoryImport() throws {
        let builder = try SVNCommandBuilder(executableURL: executableURL)
        let invocation = try builder.makeInvocation(
            for: .add(
                paths: ["ImportedProject"],
                parents: true,
                force: true,
                depth: .infinity
            ),
            in: WorkingCopy(localPath: rootURL)
        )

        XCTAssertEqual(
            invocation.arguments,
            [
                "add", "--force", "--parents", "--depth", "infinity",
                "--non-interactive", "--", "ImportedProject"
            ]
        )
    }

    func testLargeAddUsesTargetsFileAndPreservesOptionsAndLiteralNewlines() throws {
        let paths = (0..<4_100).map { "file-\($0).txt" } + ["-option", "测试 space@x.txt", "line\nbreak.txt", "carriage\rreturn.txt"]
        let invocation = try SVNCommandBuilder(executableURL: executableURL).makeInvocation(
            for: .add(paths: paths, parents: true, force: true, depth: .infinity),
            in: WorkingCopy(localPath: rootURL)
        )
        XCTAssertEqual(Array(invocation.arguments.prefix(6)), ["add", "--force", "--parents", "--depth", "infinity", "--non-interactive"])
        XCTAssertEqual(invocation.argumentFiles.count, 1)
        let targets = try XCTUnwrap(invocation.argumentFiles.first)
        XCTAssertEqual(invocation.arguments[targets.argumentIndex - 1], "--targets")
        XCTAssertEqual(targets.contents, Data((paths.dropLast(2).map { "./" + $0 + ($0.contains("@") ? "@" : "") }.joined(separator: "\n") + "\n").utf8))
        XCTAssertEqual(Array(invocation.arguments.suffix(3)), ["--", "line\nbreak.txt", "carriage\rreturn.txt"])
        XCTAssertLessThan(invocation.arguments.count, 15)
    }

    func testAddTargetsFileThresholdsUseCountAndUTF8Bytes() throws {
        let builder = try SVNCommandBuilder(executableURL: executableURL)
        let copy = WorkingCopy(localPath: rootURL)
        func invocation(_ paths: [String]) throws -> ProcessInvocation {
            try builder.makeInvocation(for: .add(paths: paths, parents: false, force: false, depth: nil), in: copy)
        }
        XCTAssertTrue(try invocation((0..<1_000).map { "file-\($0)" }).argumentFiles.isEmpty)
        XCTAssertEqual(try invocation((0..<1_001).map { "file-\($0)" }).argumentFiles.count, 1)
        let exactLimit = (0..<500).map { String(repeating: "x", count: 123) + String(format: "%04d", $0) }
        XCTAssertEqual(exactLimit.reduce(0) { $0 + $1.utf8.count + 1 }, 64_000)
        XCTAssertTrue(try invocation(exactLimit).argumentFiles.isEmpty)
        XCTAssertEqual(try invocation(exactLimit + ["x"]).argumentFiles.count, 1)
        let unicode = (0..<400).map { String(repeating: "长", count: 60) + String($0) }
        XCTAssertLessThan(unicode.joined().count, 64_000)
        XCTAssertEqual(try invocation(unicode).argumentFiles.count, 1)
    }

    func testLargeAddRejectsEntireSelectionContainingOutsidePath() throws {
        let paths = (0..<4_100).map { "file-\($0).txt" } + ["../outside.txt"]
        XCTAssertThrowsError(try SVNCommandBuilder(executableURL: executableURL).makeInvocation(
            for: .add(paths: paths, parents: true, force: true, depth: nil),
            in: WorkingCopy(localPath: rootURL)
        )) { error in
            XCTAssertEqual(error as? SVNCommandBuilderError, .pathOutsideWorkingCopy("../outside.txt"))
        }
    }

    func testRecursiveRevertUnschedulesAddWithoutRemovingFiles() throws {
        let builder = try SVNCommandBuilder(executableURL: executableURL)
        let invocation = try builder.makeInvocation(
            for: .revert(paths: ["ImportedProject"], depth: .infinity),
            in: WorkingCopy(localPath: rootURL)
        )

        XCTAssertEqual(
            invocation.arguments,
            [
                "revert", "--depth", "infinity", "--non-interactive",
                "--", "ImportedProject"
            ]
        )
        XCTAssertFalse(invocation.arguments.contains("--remove-added"))
    }

    func testDiffKeepsAtSignFilenameLiteral() throws {
        let builder = try SVNCommandBuilder(executableURL: executableURL)
        let invocation = try builder.makeInvocation(
            for: .diff(paths: ["notes/user@example.txt"]),
            in: WorkingCopy(localPath: rootURL)
        )

        XCTAssertEqual(
            invocation.arguments,
            [
                "diff", "--internal-diff", "--non-interactive",
                "--", "notes/user@example.txt"
            ]
        )
    }

    func testShellMetacharactersRemainOneArgument() throws {
        let builder = try SVNCommandBuilder(executableURL: executableURL)
        let message = "fix; touch /tmp/should-never-run"
        let invocation = try builder.makeInvocation(
            for: .commit(paths: ["README.md"], message: message, keepLocks: false),
            in: WorkingCopy(localPath: rootURL)
        )

        XCTAssertFalse(invocation.arguments.contains(message))
        XCTAssertEqual(invocation.standardInput, Data(message.utf8))
        XCTAssertTrue(invocation.arguments.contains("/dev/stdin"))
    }

    func testLargeCommitUsesOneTargetsFile() throws {
        let paths = (0..<60_372).map { "assets/file-\($0).txt" }
        let invocation = try SVNCommandBuilder(executableURL: executableURL).makeInvocation(
            for: .commit(paths: paths, message: "large commit", keepLocks: true),
            in: WorkingCopy(localPath: rootURL)
        )

        XCTAssertLessThan(invocation.arguments.count, 10)
        XCTAssertTrue(invocation.arguments.contains("--no-unlock"))
        let targets = try XCTUnwrap(invocation.argumentFiles.first)
        XCTAssertEqual(invocation.argumentFiles.count, 1)
        XCTAssertEqual(invocation.arguments[targets.argumentIndex - 1], "--targets")
        XCTAssertEqual(
            String(decoding: targets.contents, as: UTF8.self),
            paths.map { "./" + $0 }.joined(separator: "\n") + "\n"
        )
        XCTAssertEqual(invocation.standardInput, Data("large commit".utf8))
    }

    func testCommitTargetsPreserveSpecialFilenames() throws {
        let invocation = try SVNCommandBuilder(executableURL: executableURL).makeInvocation(
            for: .commit(
                paths: ["-option", "测试 space@x.txt", "line\nbreak.txt", "carriage\rreturn.txt"],
                message: "special names",
                keepLocks: false
            ),
            in: WorkingCopy(localPath: rootURL)
        )

        XCTAssertEqual(invocation.argumentFiles.first?.contents, Data("./-option\n./测试 space@x.txt@\n".utf8))
        XCTAssertEqual(Array(invocation.arguments.suffix(3)), ["--", "line\nbreak.txt", "carriage\rreturn.txt"])
    }

    func testTraversalOutsideWorkingCopyIsRejected() throws {
        let builder = try SVNCommandBuilder(executableURL: executableURL)

        XCTAssertThrowsError(try builder.makeInvocation(
            for: .diff(paths: ["../../outside.txt"]),
            in: WorkingCopy(localPath: rootURL)
        )) { error in
            XCTAssertEqual(
                error as? SVNCommandBuilderError,
                .pathOutsideWorkingCopy("../../outside.txt")
            )
        }
    }

    func testPrefixCollisionOutsideWorkingCopyIsRejected() throws {
        let builder = try SVNCommandBuilder(executableURL: executableURL)

        XCTAssertThrowsError(try builder.makeInvocation(
            for: .diff(paths: ["/tmp/SvnDockTests/WorkingCopy-Evil/file.txt"]),
            in: WorkingCopy(localPath: rootURL)
        ))
    }

    func testPhysicalRootAliasKeepsDeletedAndMissingPathsInsideWorkingCopy() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("SvnDock-path-alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("deleted.txt")
        try Data("before deletion".utf8).write(to: file)
        let copy = WorkingCopy(localPath: root)
        let builder = try SVNCommandBuilder(executableURL: executableURL)
        let before = try builder.makeInvocation(for: .diff(paths: [file.path]), in: copy)
        try FileManager.default.removeItem(at: file)
        let after = try builder.makeInvocation(for: .diff(paths: [file.path]), in: copy)
        XCTAssertEqual(before.arguments, after.arguments)
        XCTAssertEqual(after.arguments.last, "deleted.txt")

        let missing = root.appendingPathComponent("missing-directory/child.txt")
        let invocation = try builder.makeInvocation(for: .revert(paths: [missing.path], depth: .empty), in: copy)
        XCTAssertEqual(invocation.arguments.last, "missing-directory/child.txt")
        for outside in [root.path + "-sibling/file.txt", root.path + "/../outside.txt"] {
            XCTAssertThrowsError(try builder.makeInvocation(for: .diff(paths: [outside]), in: copy))
        }
    }

    func testOperationMustBelongToWorkingCopy() throws {
        let builder = try SVNCommandBuilder(executableURL: executableURL)
        let workingCopy = WorkingCopy(localPath: rootURL)
        let operation = SVNOperation(workingCopyID: UUID(), kind: .cleanup)

        XCTAssertThrowsError(try builder.makeInvocation(for: operation, in: workingCopy)) { error in
            XCTAssertEqual(error as? SVNCommandBuilderError, .operationWorkingCopyMismatch)
        }
    }

    func testEmptyCommitMessageAndNegativeRevisionAreRejected() throws {
        let builder = try SVNCommandBuilder(executableURL: executableURL)
        let workingCopy = WorkingCopy(localPath: rootURL)

        XCTAssertThrowsError(try builder.makeInvocation(
            for: .commit(paths: [], message: "  \n", keepLocks: false),
            in: workingCopy
        ))

        XCTAssertThrowsError(try builder.makeInvocation(
            for: .update(revision: .number(-1)),
            in: workingCopy
        ))
    }

    func testLogBuildsBoundedXMLCommand() throws {
        let builder = try SVNCommandBuilder(executableURL: executableURL)
        let workingCopy = WorkingCopy(localPath: rootURL)
        let invocation = try builder.makeInvocation(
            for: .log(paths: ["Sources/App.swift"], limit: 50),
            in: workingCopy
        )

        XCTAssertEqual(
            invocation.arguments,
            [
                "log", "--xml", "--revision", "HEAD:1", "--limit", "50", "--non-interactive",
                "--", "Sources/App.swift"
            ]
        )
        XCTAssertThrowsError(try builder.makeInvocation(
            for: .log(paths: [], limit: 0),
            in: workingCopy
        )) { error in
            XCTAssertEqual(error as? SVNCommandBuilderError, .invalidLogLimit(0))
        }
    }

    func testResolveRequiresPathsAndEscapesPegRevision() throws {
        let builder = try SVNCommandBuilder(executableURL: executableURL)
        let workingCopy = WorkingCopy(localPath: rootURL)
        let invocation = try builder.makeInvocation(
            for: .resolve(paths: ["conflicts/user@example.txt"], accept: .working),
            in: workingCopy
        )

        XCTAssertEqual(
            invocation.arguments,
            [
                "resolve", "--accept", "working", "--depth", "empty", "--non-interactive",
                "--", "conflicts/user@example.txt@"
            ]
        )
        XCTAssertThrowsError(try builder.makeInvocation(
            for: .resolve(paths: [], accept: .working),
            in: workingCopy
        )) { error in
            XCTAssertEqual(error as? SVNCommandBuilderError, .pathsRequired("resolve"))
        }
    }

    func testPropertiesAndIgnoreUseSafeArgumentsAndStdin() throws {
        let builder = try SVNCommandBuilder(executableURL: executableURL)
        let workingCopy = WorkingCopy(localPath: rootURL)

        let list = try builder.makeInvocation(
            for: .properties(paths: ["Assets@2x"]),
            in: workingCopy
        )
        XCTAssertEqual(
            list.arguments,
            [
                "proplist", "--xml", "--verbose", "--non-interactive",
                "--", "Assets@2x@"
            ]
        )

        let set = try builder.makeInvocation(
            for: .setIgnore(path: ".", patterns: [".build", "*.xcuserstate"]),
            in: workingCopy
        )
        XCTAssertEqual(
            set.arguments,
            [
                "propset", "svn:ignore", "--file", "/dev/stdin",
                "--non-interactive", "--", "."
            ]
        )
        XCTAssertEqual(set.standardInput, Data(".build\n*.xcuserstate\n".utf8))

        XCTAssertThrowsError(try builder.makeInvocation(
            for: .setIgnore(path: ".", patterns: ["safe\nextra-rule"]),
            in: workingCopy
        )) { error in
            XCTAssertEqual(
                error as? SVNCommandBuilderError,
                .invalidIgnorePattern("safe\nextra-rule")
            )
        }
    }
}
