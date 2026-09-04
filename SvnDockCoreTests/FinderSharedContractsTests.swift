import Foundation
import XCTest
@testable import SvnDockCore

final class FinderSharedContractsTests: XCTestCase {
    func testRegisterAndUnregisterWorkingCopies() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FinderSharedStore(directoryURL: directory)
        let first = WorkingCopy(
            name: "Beta",
            localPath: URL(fileURLWithPath: "/tmp/wc-beta", isDirectory: true)
        )
        let second = WorkingCopy(
            name: "Alpha",
            localPath: URL(fileURLWithPath: "/tmp/wc-alpha", isDirectory: true)
        )

        _ = try await store.register(first)
        _ = try await store.register(second)
        var document = try await store.loadRegisteredRoots()

        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.roots.map(\.displayName), ["Alpha", "Beta"])
        XCTAssertEqual(Set(document.roots.map(\.id)), Set([first.id, second.id]))

        _ = try await store.unregister(id: first.id)
        document = try await store.loadRegisteredRoots()
        XCTAssertEqual(document.roots.map(\.id), [second.id])
    }

    func testEncodedDocumentsUseExactFinderFieldNamesAndFractionalDates() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FinderSharedStore(directoryURL: directory)

        try await store.writeBadgeSnapshot(BadgeSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_788_486_123.456),
            entries: ["/tmp/wc/file.txt": .modified]
        ))

        let url = directory.appendingPathComponent("badge-snapshot.json")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(object["generatedAt"] as? String)
        XCTAssertNotNil(object["entries"] as? [String: String])
        XCTAssertTrue((object["generatedAt"] as? String)?.contains(".") == true)
    }

    func testReadsRealFinderCommandWithFractionalSeconds() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = directory.appendingPathComponent("command-queue", isDirectory: true)
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        let id = try XCTUnwrap(UUID(uuidString: "ABCDEF12-3456-4789-ABCD-EF1234567890"))
        let json = """
        {
          "schemaVersion": 1,
          "id": "\(id.uuidString)",
          "kind": "diff",
          "paths": ["/tmp/wc/file.txt"],
          "workingCopyRoot": "/tmp/wc",
          "createdAt": "2026-09-04T01:02:03.456Z",
          "source": "finder-extension"
        }
        """
        let commandURL = queue
            .appendingPathComponent(id.uuidString.lowercased())
            .appendingPathExtension("json")
        try Data(json.utf8).write(to: commandURL)

        let store = try FinderSharedStore(directoryURL: directory)
        let commands = try await store.loadCommands()

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].id, id)
        XCTAssertEqual(commands[0].kind, .diff)
        XCTAssertEqual(commands[0].source, "finder-extension")
        XCTAssertEqual(commands[0].paths, ["/tmp/wc/file.txt"])

        try await store.removeCommand(id: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: commandURL.path))
    }

    func testBadgeDateDecoderAcceptsWholeAndFractionalSeconds() async throws {
        for timestamp in ["2026-09-04T01:02:03Z", "2026-09-04T01:02:03.789Z"] {
            let directory = makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let json = """
            {
              "schemaVersion": 1,
              "generatedAt": "\(timestamp)",
              "entries": {"/tmp/wc/file.txt": "added"}
            }
            """
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(json.utf8).write(
                to: directory.appendingPathComponent("badge-snapshot.json")
            )

            let store = try FinderSharedStore(directoryURL: directory)
            let snapshot = try await store.loadBadgeSnapshot()
            XCTAssertEqual(snapshot.entries["/tmp/wc/file.txt"], .added)
        }
    }

    func testEnqueueUsesLowercaseUUIDFilename() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FinderSharedStore(directoryURL: directory)
        let command = FinderCommand(
            kind: .update,
            paths: ["/tmp/wc"],
            workingCopyRoot: "/tmp/wc"
        )

        let url = try await store.enqueue(command)

        XCTAssertEqual(
            url.lastPathComponent,
            "\(command.id.uuidString.lowercased()).json"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testLoadCommandByIDIgnoresMalformedSibling() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FinderSharedStore(directoryURL: directory)
        let command = FinderCommand(
            kind: .diff,
            paths: ["/tmp/wc/file.txt"],
            workingCopyRoot: "/tmp/wc"
        )
        _ = try await store.enqueue(command)
        try Data("not-json".utf8).write(
            to: directory
                .appendingPathComponent("command-queue", isDirectory: true)
                .appendingPathComponent("malformed.json")
        )

        let loaded = try await store.loadCommand(id: command.id)

        XCTAssertEqual(loaded, command)
    }

    func testLoadCommandByIDRejectsMismatchedPayloadID() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FinderSharedStore(directoryURL: directory)
        let expectedID = UUID()
        let actualCommand = FinderCommand(
            kind: .update,
            paths: ["/tmp/wc"],
            workingCopyRoot: "/tmp/wc"
        )
        let queue = directory.appendingPathComponent("command-queue", isDirectory: true)
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(actualCommand).write(
            to: queue
                .appendingPathComponent(expectedID.uuidString.lowercased())
                .appendingPathExtension("json")
        )

        do {
            _ = try await store.loadCommand(id: expectedID)
            XCTFail("Expected an identifier mismatch")
        } catch let error as FinderSharedStoreError {
            XCTAssertEqual(
                error,
                .commandIdentifierMismatch(expected: expectedID, actual: actualCommand.id)
            )
        }
    }

    func testRejectsRelativeSharedPaths() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FinderSharedStore(directoryURL: directory)

        do {
            try await store.writeBadgeSnapshot(BadgeSnapshot(entries: ["relative/file": .modified]))
            XCTFail("Expected relative path to be rejected")
        } catch let error as FinderSharedStoreError {
            XCTAssertEqual(error, .pathIsNotAbsolute("relative/file"))
        }
    }

    func testBadgeSliceReplacementPreservesNestedWorkingCopyEntries() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FinderSharedStore(directoryURL: directory)
        let parent = WorkingCopy(
            localPath: URL(fileURLWithPath: "/tmp/svndock-parent", isDirectory: true)
        )
        let child = WorkingCopy(
            localPath: URL(fileURLWithPath: "/tmp/svndock-parent/external", isDirectory: true)
        )
        _ = try await store.register(parent)
        _ = try await store.register(child)

        try await store.replaceBadgeEntries(
            forWorkingCopyID: child.id,
            underWorkingCopyRoot: child.localPath.path,
            with: ["/tmp/svndock-parent/external/child.txt": .modified]
        )
        try await store.replaceBadgeEntries(
            forWorkingCopyID: parent.id,
            underWorkingCopyRoot: parent.localPath.path,
            with: ["/tmp/svndock-parent/parent.txt": .added]
        )

        let entries = try await store.loadBadgeSnapshot().entries
        XCTAssertEqual(entries["/tmp/svndock-parent/parent.txt"], .added)
        XCTAssertEqual(entries["/tmp/svndock-parent/external/child.txt"], .modified)
    }

    func testConcurrentBadgeSliceReplacementDoesNotLoseAnotherRoot() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstStore = try FinderSharedStore(directoryURL: directory)
        let secondStore = try FinderSharedStore(directoryURL: directory)
        let firstCopy = WorkingCopy(
            localPath: URL(fileURLWithPath: "/tmp/svndock-first", isDirectory: true)
        )
        let secondCopy = WorkingCopy(
            localPath: URL(fileURLWithPath: "/tmp/svndock-second", isDirectory: true)
        )
        _ = try await firstStore.register(firstCopy)
        _ = try await firstStore.register(secondCopy)

        async let first: Void = firstStore.replaceBadgeEntries(
            forWorkingCopyID: firstCopy.id,
            underWorkingCopyRoot: "/tmp/svndock-first",
            with: ["/tmp/svndock-first/file.txt": .added]
        )
        async let second: Void = secondStore.replaceBadgeEntries(
            forWorkingCopyID: secondCopy.id,
            underWorkingCopyRoot: "/tmp/svndock-second",
            with: ["/tmp/svndock-second/file.txt": .conflicted]
        )
        _ = try await (first, second)

        let entries = try await firstStore.loadBadgeSnapshot().entries
        XCTAssertEqual(entries["/tmp/svndock-first/file.txt"], .added)
        XCTAssertEqual(entries["/tmp/svndock-second/file.txt"], .conflicted)
    }

    func testDelayedNestedCleanupPreservesNewerParentOwnedEntry() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FinderSharedStore(directoryURL: directory)
        let parent = WorkingCopy(
            localPath: URL(fileURLWithPath: "/tmp/svndock-owner-parent", isDirectory: true)
        )
        let child = WorkingCopy(
            localPath: URL(
                fileURLWithPath: "/tmp/svndock-owner-parent/external",
                isDirectory: true
            )
        )
        _ = try await store.register(parent)
        _ = try await store.register(child)
        try await store.replaceBadgeEntries(
            forWorkingCopyID: child.id,
            underWorkingCopyRoot: child.localPath.path,
            with: ["/tmp/svndock-owner-parent/external/file.txt": .modified]
        )

        _ = try await store.unregister(id: child.id)
        try await store.replaceBadgeEntries(
            forWorkingCopyID: parent.id,
            underWorkingCopyRoot: parent.localPath.path,
            with: ["/tmp/svndock-owner-parent/external/file.txt": .unversioned]
        )
        try await store.removeBadgeEntries(
            forUnregisteredWorkingCopyID: child.id,
            underWorkingCopyRoot: child.localPath.path
        )

        let snapshot = try await store.loadBadgeSnapshot()
        XCTAssertEqual(
            snapshot.entries["/tmp/svndock-owner-parent/external/file.txt"],
            .unversioned
        )
        XCTAssertEqual(
            snapshot.entryOwners?["/tmp/svndock-owner-parent/external/file.txt"],
            parent.id
        )
    }

    func testSamePathReplacementRejectsStaleBadgeWriterAndCleanup() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FinderSharedStore(directoryURL: directory)
        let path = URL(fileURLWithPath: "/tmp/svndock-owner-replaced", isDirectory: true)
        let stale = WorkingCopy(name: "Stale", localPath: path)
        let replacement = WorkingCopy(name: "Replacement", localPath: path)
        _ = try await store.register(stale)
        try await store.replaceBadgeEntries(
            forWorkingCopyID: stale.id,
            underWorkingCopyRoot: path.path,
            with: ["/tmp/svndock-owner-replaced/file.txt": .modified]
        )
        _ = try await store.register(replacement)
        try await store.removeBadgeEntries(
            forUnregisteredWorkingCopyID: stale.id,
            underWorkingCopyRoot: path.path
        )
        let clearedSnapshot = try await store.loadBadgeSnapshot()
        XCTAssertNil(clearedSnapshot.entries["/tmp/svndock-owner-replaced/file.txt"])

        do {
            try await store.replaceBadgeEntries(
                forWorkingCopyID: stale.id,
                underWorkingCopyRoot: path.path,
                with: ["/tmp/svndock-owner-replaced/file.txt": .modified]
            )
            XCTFail("Expected a stale UUID to be rejected")
        } catch let error as FinderSharedStoreError {
            XCTAssertEqual(error, .badgeRootNotRegistered(path.path))
        }

        try await store.replaceBadgeEntries(
            forWorkingCopyID: replacement.id,
            underWorkingCopyRoot: path.path,
            with: ["/tmp/svndock-owner-replaced/file.txt": .added]
        )
        try await store.removeBadgeEntries(
            forUnregisteredWorkingCopyID: stale.id,
            underWorkingCopyRoot: path.path
        )
        let snapshot = try await store.loadBadgeSnapshot()
        XCTAssertEqual(snapshot.entries["/tmp/svndock-owner-replaced/file.txt"], .added)
        XCTAssertEqual(
            snapshot.entryOwners?["/tmp/svndock-owner-replaced/file.txt"],
            replacement.id
        )
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SvnDockShared-\(UUID().uuidString)", isDirectory: true)
    }
}
