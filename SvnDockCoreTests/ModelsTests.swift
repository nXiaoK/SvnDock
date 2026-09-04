import Foundation
import XCTest
@testable import SvnDockCore

final class ModelsTests: XCTestCase {
    func testWorkingCopyUsesDirectoryNameByDefault() {
        let id = UUID()
        let workingCopy = WorkingCopy(
            id: id,
            localPath: URL(fileURLWithPath: "/tmp/Projects/Example", isDirectory: true),
            repositoryURL: URL(string: "https://svn.example.test/repos/Example")
        )

        XCTAssertEqual(workingCopy.id, id)
        XCTAssertEqual(workingCopy.name, "Example")
        XCTAssertEqual(workingCopy.canonicalPath, "/tmp/Projects/Example")
        XCTAssertTrue(workingCopy.isEnabled)
    }

    func testUnknownStatusRoundTripsItsOriginalValue() throws {
        let original = SVNStatus.unknown("future-status")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SVNStatus.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.svnValue, "future-status")
        XCTAssertFalse(decoded.isLocalChange)
    }

    func testStatusEntryDerivesDirectoryAndChangeFlags() {
        let entry = StatusEntry(
            path: "Sources",
            kind: .directory,
            status: .normal,
            propertyStatus: .modified
        )

        XCTAssertTrue(entry.isDirectory)
        XCTAssertTrue(entry.hasLocalChanges)
        XCTAssertEqual(BadgeKind(statusEntry: entry), .modified)
    }

    func testTreeConflictHasConflictBadgePriority() {
        let entry = StatusEntry(
            path: "README.md",
            kind: .file,
            status: .modified,
            isTreeConflicted: true
        )

        XCTAssertEqual(BadgeKind(statusEntry: entry), .conflicted)
    }

    func testPropertyConflictHasConflictBadgePriority() {
        let entry = StatusEntry(
            path: ".",
            kind: .directory,
            status: .normal,
            propertyStatus: .conflicted
        )

        XCTAssertEqual(BadgeKind(statusEntry: entry), .conflicted)
    }

    func testStatusOptionsDecodeLegacyPayloadWithoutScopedPaths() throws {
        let data = Data(#"{"showRemoteUpdates":false,"includeIgnored":true}"#.utf8)
        let options = try JSONDecoder().decode(SVNStatusOptions.self, from: data)

        XCTAssertFalse(options.showRemoteUpdates)
        XCTAssertTrue(options.includeIgnored)
        XCTAssertEqual(options.paths, [])
    }
}
