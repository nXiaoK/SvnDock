import Foundation
import XCTest
@testable import SvnDockCore

final class SVNXMLParserTests: XCTestCase {
    func testParsesStatusXMLIncludingChangelistAndRemoteState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SvnDockStatus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceDirectory = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <status>
          <target path=".">
            <entry path="README&amp;Notes.md">
              <wc-status item="modified" props="none" revision="41" copied="true" switched="false" tree-conflicted="true">
                <commit revision="40">
                  <author>alice</author>
                  <date>2026-09-04T01:02:03.456789Z</date>
                </commit>
              </wc-status>
              <repos-status item="modified" props="none" />
            </entry>
          </target>
          <changelist name="release-fix">
            <entry path="Sources">
              <wc-status item="added" props="modified" revision="41" />
            </entry>
          </changelist>
        </status>
        """

        let entries = try SVNXMLParser.parseStatus(Data(xml.utf8), workingCopyURL: root)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].path, "README&Notes.md")
        XCTAssertEqual(entries[0].status, .modified)
        XCTAssertEqual(entries[0].repositoryStatus, .modified)
        XCTAssertEqual(entries[0].revision, 41)
        XCTAssertTrue(entries[0].isCopied)
        XCTAssertTrue(entries[0].isTreeConflicted)
        XCTAssertEqual(entries[0].lastCommit?.revision, 40)
        XCTAssertEqual(entries[0].lastCommit?.author, "alice")
        XCTAssertNotNil(entries[0].lastCommit?.date)

        XCTAssertEqual(entries[1].path, "Sources")
        XCTAssertEqual(entries[1].kind, .directory)
        XCTAssertEqual(entries[1].status, .added)
        XCTAssertEqual(entries[1].propertyStatus, .modified)
        XCTAssertEqual(entries[1].changelist, "release-fix")
    }

    func testCanSkipFilesystemNodeKindResolutionForLargeStatusScans() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SvnDockStatus-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let xml = """
        <status><target path=".">
          <entry path="Sources"><wc-status item="added" props="none" /></entry>
        </target></status>
        """

        let entries = try SVNXMLParser.parseStatus(
            Data(xml.utf8),
            workingCopyURL: root,
            resolveNodeKinds: false
        )

        XCTAssertEqual(entries.first?.kind, .unknown)
    }

    func testParsesInfoXML() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <info>
          <entry kind="dir" path="." revision="42">
            <url>https://svn.example.test/repos/project/trunk</url>
            <relative-url>^/project/trunk</relative-url>
            <repository>
              <root>https://svn.example.test/repos</root>
              <uuid>68f9a7ac-1f66-4d69-a22e-102b56dba218</uuid>
            </repository>
            <wc-info>
              <wcroot-abspath>/Users/test/Project</wcroot-abspath>
              <schedule>normal</schedule>
              <depth>infinity</depth>
            </wc-info>
            <commit revision="39">
              <author>bob</author>
              <date>2026-09-01T08:30:00Z</date>
            </commit>
          </entry>
        </info>
        """

        let info = try SVNXMLParser.parseInfo(Data(xml.utf8))

        XCTAssertEqual(info.path, ".")
        XCTAssertEqual(info.kind, .directory)
        XCTAssertEqual(info.revision, 42)
        XCTAssertEqual(info.url?.absoluteString, "https://svn.example.test/repos/project/trunk")
        XCTAssertEqual(info.repositoryRootURL?.absoluteString, "https://svn.example.test/repos")
        XCTAssertEqual(info.repositoryUUID, "68f9a7ac-1f66-4d69-a22e-102b56dba218")
        XCTAssertEqual(info.workingCopyRootURL?.path, "/Users/test/Project")
        XCTAssertEqual(info.schedule, "normal")
        XCTAssertEqual(info.depth, "infinity")
        XCTAssertEqual(info.lastCommit?.revision, 39)
        XCTAssertEqual(info.lastCommit?.author, "bob")
        XCTAssertNotNil(info.lastCommit?.date)
    }

    func testInfoPreservesPathWhitespaceWhileNormalizingProtocolValues() throws {
        for path in ["/Users/test/Project ", "/Users/test/Project\t", "/Users/test/Project\n", "/Users/test/Project & Notes  "] {
            let escapedPath = path.replacingOccurrences(of: "&", with: "&amp;")
            let xml = """
            <info><entry kind="dir" path="Project " revision="42">
              <url> https://svn.example.test/repo/Project%20 </url>
              <repository><root> https://svn.example.test/repo </root><uuid> fixture </uuid></repository>
              <wc-info><wcroot-abspath>\(escapedPath)</wcroot-abspath><schedule> normal </schedule><depth> infinity </depth></wc-info>
              <commit revision="39"><author> bob </author><date> 2026-09-01T08:30:00Z </date></commit>
            </entry></info>
            """
            let info = try SVNXMLParser.parseInfo(Data(xml.utf8))
            XCTAssertEqual(info.path, "Project ")
            XCTAssertEqual(info.workingCopyRootURL?.path, path)
            XCTAssertEqual(info.url?.absoluteString, "https://svn.example.test/repo/Project%20")
            XCTAssertEqual(info.repositoryRootURL?.absoluteString, "https://svn.example.test/repo")
            XCTAssertEqual(info.repositoryUUID, "fixture")
            XCTAssertEqual(info.schedule, "normal")
            XCTAssertEqual(info.depth, "infinity")
            XCTAssertEqual(info.lastCommit?.author, "bob")
            XCTAssertNotNil(info.lastCommit?.date)
        }
    }

    func testMalformedXMLThrowsStructuredError() {
        XCTAssertThrowsError(try SVNXMLParser.parseStatus(Data("<status><entry>".utf8))) { error in
            guard case SVNXMLParserError.malformedXML = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testInfoWithoutEntryThrows() {
        XCTAssertThrowsError(try SVNXMLParser.parseInfo(Data("<info />".utf8))) { error in
            XCTAssertEqual(error as? SVNXMLParserError, .missingRequiredValue("info/entry"))
        }
    }

    func testParsesLogXML() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <log>
          <logentry revision="52">
            <author>alice</author>
            <date>2026-09-04T02:03:04.123456Z</date>
            <msg>Fix Finder &amp; queue handling</msg>
          </logentry>
          <logentry revision="51">
            <msg></msg>
          </logentry>
        </log>
        """

        let entries = try SVNXMLParser.parseLog(Data(xml.utf8))

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].revision, 52)
        XCTAssertEqual(entries[0].author, "alice")
        XCTAssertNotNil(entries[0].date)
        XCTAssertEqual(entries[0].message, "Fix Finder & queue handling")
        XCTAssertEqual(entries[1].revision, 51)
        XCTAssertNil(entries[1].author)
        XCTAssertEqual(entries[1].message, "")
    }

    func testLogEntryWithoutRevisionThrows() {
        let xml = "<log><logentry><msg>invalid</msg></logentry></log>"
        XCTAssertThrowsError(try SVNXMLParser.parseLog(Data(xml.utf8))) { error in
            XCTAssertEqual(
                error as? SVNXMLParserError,
                .missingRequiredValue("log/logentry@revision")
            )
        }
    }

    func testLogMessagePreservesIntentionalWhitespace() throws {
        let xml = "<log><logentry revision=\"7\"><msg>\nTitle\n\nBody\n</msg></logentry></log>"
        let entries = try SVNXMLParser.parseLog(Data(xml.utf8))

        XCTAssertEqual(entries.first?.message, "\nTitle\n\nBody\n")
    }

    func testDateParsingSupportsMixedFormatsWithoutLeakingPreviousValues() throws {
        let dates = ["2026-09-04T02:03:04.125Z", "2026-09-04T02:03:04Z", "invalid", ""]
        let xml = "<log>" + dates.enumerated().map { index, date in
            "<logentry revision=\"\(index + 1)\"><date>\(date)</date><msg/></logentry>"
        }.joined() + "</log>"
        let entries = try SVNXMLParser.parseLog(Data(xml.utf8))
        XCTAssertEqual(entries.count, dates.count)
        XCTAssertEqual(try XCTUnwrap(entries[0].date).timeIntervalSince(try XCTUnwrap(entries[1].date)), 0.125, accuracy: 0.001)
        XCTAssertNil(entries[2].date)
        XCTAssertNil(entries[3].date)
    }

    func testParsesVerbosePropertiesXMLWithoutLosingIgnoreLines() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <properties>
          <target path=".">
            <property name="svn:ignore">.build
        *.xcuserstate
        Notes &amp; Drafts</property>
            <property name="custom:empty"></property>
          </target>
        </properties>
        """

        let entries = try SVNXMLParser.parseProperties(Data(xml.utf8))

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].path, ".")
        XCTAssertEqual(
            entries[0].value(forProperty: "svn:ignore"),
            ".build\n*.xcuserstate\nNotes & Drafts"
        )
        XCTAssertEqual(entries[0].value(forProperty: "custom:empty"), "")
    }

    func testRejectsEncodedPropertyInsteadOfOverwritingOpaqueValue() {
        let xml = """
        <properties><target path=".">
          <property name="svn:ignore" encoding="base64">AAE=</property>
        </target></properties>
        """

        XCTAssertThrowsError(try SVNXMLParser.parseProperties(Data(xml.utf8))) { error in
            XCTAssertEqual(
                error as? SVNXMLParserError,
                .unsupportedPropertyEncoding("base64")
            )
        }
    }
}
