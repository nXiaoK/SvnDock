import Foundation
import XCTest
@testable import SvnDockFinderExtension

final class SharedStateStoreTests: XCTestCase {
    func testUnchangedCallbacksReuseDecodedSnapshots() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeRoots([fixture.root])
        try fixture.writeBadges(.modified)

        for _ in 0..<20 {
            XCTAssertEqual(fixture.state.reload(), [fixture.root])
            XCTAssertEqual(fixture.state.badge(for: fixture.fileURL), .modified)
        }

        XCTAssertEqual(fixture.loader.rootLoads, 1)
        XCTAssertEqual(fixture.loader.badgeLoads, 1)
    }

    func testBadgeReplacementReloadsOnlyBadgesEvenWithSameSizeAndDate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeRoots([fixture.root])
        try fixture.writeBadges(.modified)
        fixture.state.reload()
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.loader.badgeSnapshotURL!.path
        )

        try fixture.writeBadges(.replaced)
        try FileManager.default.setAttributes(
            [.modificationDate: attributes[.modificationDate]!],
            ofItemAtPath: fixture.loader.badgeSnapshotURL!.path
        )
        fixture.state.reload()

        XCTAssertEqual(fixture.state.badge(for: fixture.fileURL), .replaced)
        XCTAssertEqual(fixture.loader.rootLoads, 1)
        XCTAssertEqual(fixture.loader.badgeLoads, 2)
    }

    func testRemovedAndMalformedRegistryImmediatelyClearCachedRoots() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeRoots([fixture.root])
        try fixture.writeBadges(.modified)
        fixture.state.reload()

        try Data("{".utf8).write(to: fixture.loader.registeredRootsURL!, options: .atomic)
        XCTAssertTrue(fixture.state.reload().isEmpty)
        XCTAssertNil(fixture.state.root(containing: fixture.fileURL))
        XCTAssertTrue(fixture.state.reload().isEmpty)
        XCTAssertEqual(fixture.loader.rootLoads, 2)

        try fixture.writeRoots([fixture.root])
        XCTAssertEqual(fixture.state.reload(), [fixture.root])
        try FileManager.default.removeItem(at: fixture.loader.registeredRootsURL!)
        XCTAssertTrue(fixture.state.reload().isEmpty)
        XCTAssertEqual(fixture.loader.badgeLoads, 1)
    }

    func testReplacementDuringReadIsDetectedOnNextReload() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeRoots([fixture.root])
        try fixture.writeBadges(.modified)
        fixture.loader.afterLoadingRoots = {
            fixture.loader.afterLoadingRoots = nil
            try fixture.writeRoots([])
        }

        XCTAssertEqual(fixture.state.reload(), [fixture.root])
        XCTAssertTrue(fixture.state.reload().isEmpty)
        XCTAssertEqual(fixture.loader.rootLoads, 2)
    }

    func testConcurrentReloadCannotRestoreStaleRoots() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeRoots([fixture.root])
        try fixture.writeBadges(.modified)
        let firstRead = DispatchSemaphore(value: 0)
        let allowFirstFinish = DispatchSemaphore(value: 0)
        let firstDone = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let secondDone = DispatchSemaphore(value: 0)
        defer { allowFirstFinish.signal() }
        fixture.loader.afterLoadingRoots = {
            fixture.loader.afterLoadingRoots = nil
            firstRead.signal()
            allowFirstFinish.wait()
        }
        let state = fixture.state
        DispatchQueue.global().async {
            state.reload()
            firstDone.signal()
        }
        XCTAssertEqual(firstRead.wait(timeout: .now() + 5), .success)
        try fixture.writeRoots([])
        DispatchQueue.global().async {
            secondStarted.signal()
            state.reload()
            secondDone.signal()
        }
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(secondDone.wait(timeout: .now() + 0.1), .timedOut)
        allowFirstFinish.signal()
        XCTAssertEqual(firstDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(secondDone.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(fixture.state.registeredRoots().isEmpty)
    }

    private final class Fixture {
        let directory: URL
        let root = RegisteredRoot(
            id: UUID(), path: "/tmp/working-copy", displayName: nil, enabled: true
        )
        let fileURL = URL(fileURLWithPath: "/tmp/working-copy/File.swift")
        let loader: CountingLoader
        let state: SharedStateStore

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("SvnDockFinderState-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            loader = CountingLoader(directory: directory)
            state = SharedStateStore(container: loader)
        }

        func writeRoots(_ roots: [RegisteredRoot]) throws {
            try JSONEncoder().encode(RegisteredRootsDocument(schemaVersion: 1, roots: roots))
                .write(to: loader.registeredRootsURL!, options: .atomic)
        }

        func writeBadges(_ badge: BadgeKind) throws {
            try JSONEncoder().encode(BadgeSnapshotDocument(
                schemaVersion: 1, generatedAt: nil, entries: [fileURL.path: badge]
            )).write(to: loader.badgeSnapshotURL!, options: .atomic)
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private final class CountingLoader: SharedStateLoading {
        let registeredRootsURL: URL?
        let badgeSnapshotURL: URL?
        var rootLoads = 0
        var badgeLoads = 0
        var afterLoadingRoots: (() throws -> Void)?

        init(directory: URL) {
            registeredRootsURL = directory.appendingPathComponent("registered-roots.json")
            badgeSnapshotURL = directory.appendingPathComponent("badge-snapshot.json")
        }

        func loadRegisteredRoots() throws -> [RegisteredRoot] {
            rootLoads += 1
            let roots = try JSONDecoder().decode(
                RegisteredRootsDocument.self, from: Data(contentsOf: registeredRootsURL!)
            ).roots
            try afterLoadingRoots?()
            return roots
        }

        func loadBadgeSnapshot() throws -> BadgeSnapshotDocument {
            badgeLoads += 1
            return try JSONDecoder().decode(
                BadgeSnapshotDocument.self, from: Data(contentsOf: badgeSnapshotURL!)
            )
        }
    }
}
