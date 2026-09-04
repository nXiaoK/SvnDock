import Foundation
import XCTest
@testable import SvnDockCore

final class SVNExecutableLocatorTests: XCTestCase {
    func testEnvironmentOverrideHasPriority() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SvnDockLocator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("custom-svn")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executable.path
        )

        let locator = SVNExecutableLocator(candidatePaths: ["/definitely/missing/svn"])
        let result = try locator.locate(environment: ["SVNDOCK_SVN_PATH": executable.path])

        XCTAssertEqual(result.standardizedFileURL, executable.standardizedFileURL)
    }

    func testPathLookupFindsSvnWithoutShell() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SvnDockPATH-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("svn")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executable.path
        )

        let locator = SVNExecutableLocator(candidatePaths: [])
        let result = try locator.locate(environment: ["PATH": directory.path])

        XCTAssertEqual(result.standardizedFileURL, executable.standardizedFileURL)
    }

    func testFailureListsUniqueAttemptedPaths() {
        let locator = SVNExecutableLocator(candidatePaths: ["/missing/svn", "/missing/svn"])

        XCTAssertThrowsError(try locator.locate(environment: [:])) { error in
            let notFound = error as? SVNExecutableNotFoundError
            XCTAssertEqual(notFound?.attemptedPaths, ["/missing/svn"])
        }
    }
}
