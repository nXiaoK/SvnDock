import Foundation
import XCTest
@testable import SvnDockCore

final class SVNAdditionUndoTests: XCTestCase {
    private let copy = WorkingCopy(localPath: URL(fileURLWithPath: "/tmp/undo-tests/wc"))
    private let executable = URL(fileURLWithPath: "/usr/bin/svn")

    func testCollapsesLargeMissingTreeWithoutPrefixCollisions() throws {
        let undo = try SVNAdditionUndo(executableURL: executable)
        let paths = ["pending", "pending-other/file.txt"] + (0..<60_000).map { "pending/group/file-\($0)" }
        XCTAssertEqual(try undo.targets(for: paths, in: copy), ["pending", "pending-other/file.txt"])
        XCTAssertThrowsError(try undo.targets(for: ["../outside"], in: copy))
        XCTAssertThrowsError(try undo.targets(for: [], in: copy))
    }

    func testMissingVersionedFileBlocksEntireSelectionBeforeRevert() async throws {
        let runner = AdditionUndoFixtureRunner(versioned: true)
        let undo = try SVNAdditionUndo(executableURL: executable, runner: runner)
        do {
            try await undo.run(targets: ["pending", "versioned"], in: copy, missingOnly: true)
            XCTFail("Expected a versioned-file rejection")
        } catch let error as SVNAdditionUndoError {
            XCTAssertEqual(error, .notScheduledAddition("versioned"))
        }
        let commands = await runner.commands
        XCTAssertEqual(commands, ["status", "info"])
    }

    func testMissingAdditionUsesOneRecursiveRevertAfterVerification() async throws {
        let runner = AdditionUndoFixtureRunner(versioned: false)
        let undo = try SVNAdditionUndo(executableURL: executable, runner: runner)
        try await undo.run(targets: ["pending", "pending/child"], in: copy, missingOnly: true)
        let commands = await runner.commands
        XCTAssertEqual(commands, ["status", "info", "revert"])
        let revert = await runner.lastInvocation
        XCTAssertEqual(revert?.arguments, ["revert", "--depth", "infinity", "--non-interactive", "--", "pending"])
    }
}

private actor AdditionUndoFixtureRunner: ProcessRunning {
    let versioned: Bool
    var commands: [String] = []
    var lastInvocation: ProcessInvocation?

    init(versioned: Bool) { self.versioned = versioned }

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        let command = invocation.arguments[0]
        commands.append(command)
        lastInvocation = invocation
        let xml: String
        switch command {
        case "status":
            xml = """
            <status><target path=".">
            <entry path="pending"><wc-status item="missing" props="none" revision="-1"/></entry>
            <entry path="versioned"><wc-status item="missing" props="none" revision="1"/></entry>
            </target></status>
            """
        case "info":
            xml = """
            <info><entry path="pending" kind="dir"><wc-info><schedule>add</schedule></wc-info></entry>
            \(versioned ? "<entry path=\"versioned\" kind=\"file\"><wc-info><schedule>normal</schedule></wc-info></entry>" : "")
            </info>
            """
        default:
            xml = ""
        }
        return ProcessResult(terminationStatus: 0, terminationReason: .exit, standardOutput: Data(xml.utf8), standardError: Data())
    }
}
