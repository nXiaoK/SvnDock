import Foundation
import XCTest
@testable import SvnDockCore

final class SVNMissingDeletionTests: XCTestCase {
    private let copy = WorkingCopy(localPath: URL(fileURLWithPath: "/tmp/missing-deletion-tests/wc"))
    private let executable = URL(fileURLWithPath: "/usr/bin/svn")

    func testTargetsCollapseMissingSubtreesButRejectWorkingCopyRoot() throws {
        let deletion = try SVNMissingDeletion(executableURL: executable)
        XCTAssertEqual(
            try deletion.targets(for: ["gone/child", "gone", "gone", "gone-other/child"], in: copy),
            ["gone", "gone-other/child"]
        )
        XCTAssertThrowsError(try deletion.targets(for: ["."], in: copy))
        XCTAssertThrowsError(try deletion.targets(for: [copy.localPath.path], in: copy))
        XCTAssertThrowsError(try deletion.targets(for: ["../outside"], in: copy))
        XCTAssertThrowsError(try deletion.targets(for: [], in: copy))
    }

    func testDeleteUsesLocalEscapedTargetsAndPreservesDiskContent() throws {
        let builder = try SVNCommandBuilder(executableURL: executable)
        let invocation = try builder.makeInvocation(
            for: .delete(paths: ["-option", "中文 @ file", "line\nbreak"]), in: copy
        )
        XCTAssertEqual(Array(invocation.arguments.prefix(2)), ["delete", "--keep-local"])
        XCTAssertFalse(invocation.arguments.contains("--force"))
        XCTAssertEqual(invocation.argumentFiles.first?.contents, Data("./-option\n./中文 @ file@\n".utf8))
        XCTAssertEqual(Array(invocation.arguments.suffix(2)), ["--", "line\nbreak"])
        XCTAssertTrue(SVNOperationKind.delete(paths: ["gone"]).mutatesWorkingCopy)
    }

    func testLargeDeleteKeepsAllTargetsOutOfArgv() throws {
        let builder = try SVNCommandBuilder(executableURL: executable)
        let paths = (0..<60_000).map { "file-\($0).txt" }
        let invocation = try builder.makeInvocation(for: .delete(paths: paths), in: copy)
        XCTAssertLessThan(invocation.arguments.count, 10)
        XCTAssertEqual(invocation.argumentFiles.first?.contents.split(separator: 0x0a).count, paths.count)
        XCTAssertThrowsError(try builder.makeInvocation(for: .delete(paths: []), in: copy))
        XCTAssertThrowsError(try builder.makeInvocation(for: .delete(paths: ["/outside/file"]), in: copy))
    }
}
