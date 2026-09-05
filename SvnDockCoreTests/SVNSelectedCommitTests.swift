import Foundation
#if !SVNDOCK_SELECTED_COMMIT_SMOKE
import XCTest
@testable import SvnDockCore

final class SVNSelectedCommitTests: XCTestCase {
    func testExternalMetadataPreservesStatusAndDecodesOldSnapshots() throws {
        try SelectedCommitRegressionChecks.externalMetadata()
    }

    func testCommitRejectsUnsafeSelectionsBeforeWriting() async throws {
        try await SelectedCommitRegressionChecks.selectionPreflight()
    }
}
#endif

enum SelectedCommitRegressionChecks {
    static func externalMetadata() throws {
        let xml = """
        <status><target path=".">
        <entry path="external.txt"><wc-status item="modified" props="none" file-external="true" revision="3"/></entry>
        <entry path="local.txt"><wc-status item="modified" props="none" revision="3"/></entry>
        </target></status>
        """
        let entries = try SVNXMLParser.parseStatus(Data(xml.utf8), resolveNodeKinds: false)
        try check(entries[0].isFileExternal == true && entries[0].status == .modified,
                  "file external identity must coexist with its local modification")
        try check(entries[1].isFileExternal == nil, "local files do not inherit the previous entry's external flag")
        let stored = try JSONEncoder().encode(entries[1])
        let decoded = try JSONDecoder().decode(StatusEntry.self, from: stored)
        try check(decoded == entries[1] && decoded.isFileExternal == nil,
                  "older status snapshots without the optional flag remain readable")
        let external = try JSONDecoder().decode(StatusEntry.self, from: JSONEncoder().encode(entries[0]))
        try check(external.isFileExternal == true, "external metadata survives status persistence")
    }

    static func selectionPreflight() async throws {
        let copy = WorkingCopy(localPath: FileManager.default.temporaryDirectory.appendingPathComponent("selected-commit-fixture"))
        let fixtures: [(String, [String], SVNSelectedCommitError)] = [
            (entry("external.txt", "modified", extra: "file-external=\"true\""), ["external.txt"], .externalWorkingCopy("external.txt")),
            (entry("vendor", "external") + entry("vendor/edit.txt", "modified"), ["vendor/edit.txt"], .externalWorkingCopy("vendor/edit.txt")),
            (entry("new", "added") + entry("new/edit.txt", "added"), ["new/edit.txt"], .missingParent("new")),
            (entry("good.txt", "modified") + entry("bad.txt", "conflicted"), ["good.txt", "bad.txt"], .changedSelection("bad.txt")),
            (entry("properties", "normal", properties: "conflicted"), ["properties"], .changedSelection("properties"))
        ]
        for (xml, paths, expected) in fixtures {
            let runner = SelectedCommitFixtureRunner(entriesXML: xml)
            let commit = try SVNSelectedCommit(executableURL: URL(fileURLWithPath: "/usr/bin/svn"), runner: runner)
            do {
                try await commit.run(targets: paths, message: "fixture", in: copy)
                throw Failure(message: "unsafe selection unexpectedly committed: \(paths)")
            } catch let error as SVNSelectedCommitError {
                try check(error == expected, "preflight identifies the concrete unsafe target")
            }
            let invocations = await runner.invocations
            try check(invocations.map { $0.arguments[0] } == ["status"],
                      "the entire selection is validated before starting a commit")
        }

        let runner = SelectedCommitFixtureRunner(entriesXML:
            entry("folder", "normal", properties: "modified") + entry("folder/unselected.txt", "modified"))
        let commit = try SVNSelectedCommit(executableURL: URL(fileURLWithPath: "/usr/bin/svn"), runner: runner)
        try await commit.run(targets: ["folder"], message: "fixture", in: copy)
        let invocations = await runner.invocations
        try check(invocations.map { $0.arguments[0] } == ["status", "commit"], "safe directory properties can be committed")
        let args = invocations.last?.arguments ?? []
        guard let depthIndex = args.firstIndex(of: "--depth"), let separator = args.firstIndex(of: "--") else {
            throw Failure(message: "commit must explicitly bound traversal and separate paths")
        }
        try check(args[depthIndex + 1] == "empty" && Array(args[(separator + 1)...]).isEmpty
                  && invocations.last?.argumentFiles.map(\.contents) == [Data("./folder\n".utf8)],
                  "directory properties do not pull unselected modified descendants into the command")
    }

    private static func entry(_ path: String, _ status: String, properties: String = "none", extra: String = "") -> String {
        "<entry path=\"\(path)\"><wc-status item=\"\(status)\" props=\"\(properties)\" \(extra)/></entry>"
    }

    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    private struct Failure: Error { let message: String }
}

private actor SelectedCommitFixtureRunner: ProcessRunning {
    let entriesXML: String
    var invocations: [ProcessInvocation] = []

    init(entriesXML: String) { self.entriesXML = entriesXML }

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        invocations.append(invocation)
        let output = invocation.arguments[0] == "status" ? "<status><target path=\".\">\(entriesXML)</target></status>" : ""
        return ProcessResult(terminationStatus: 0, terminationReason: .exit, standardOutput: Data(output.utf8), standardError: Data())
    }
}
