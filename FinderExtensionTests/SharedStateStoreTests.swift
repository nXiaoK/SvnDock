import Foundation
import XCTest
@testable import SvnDockFinderExtension

final class SharedStateStoreTests: XCTestCase {
    func testBadgeFreshnessUsesEachRootAndKeepsExactStatesSeparate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let second = RegisteredRoot(id: UUID(), path: "/tmp/second-copy", displayName: nil, enabled: true)
        let secondFile = URL(fileURLWithPath: second.path).appendingPathComponent("clean.txt")
        let rootURL = URL(fileURLWithPath: fixture.root.path)
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let formatter = ISO8601DateFormatter()
        try fixture.writeRoots([fixture.root, second])
        try JSONEncoder().encode(BadgeSnapshotDocument(
            schemaVersion: 1, generatedAt: formatter.string(from: now),
            entries: [rootURL.path: .conflicted, fixture.fileURL.path: .clean, secondFile.path: .clean],
            directEntries: [rootURL.path: .clean, fixture.fileURL.path: .clean, secondFile.path: .clean],
            perRootUpdatedAt: [fixture.root.path: formatter.string(from: now.addingTimeInterval(-59)),
                               second.path: formatter.string(from: now)]
        )).write(to: fixture.loader.badgeSnapshotURL!, options: .atomic)
        fixture.state.reload()
        XCTAssertEqual(fixture.state.badgeIdentifier(for: rootURL, at: now), FinderBadgeIdentifier.conflicted)
        XCTAssertEqual(fixture.state.directBadge(for: rootURL), .clean)
        XCTAssertEqual(fixture.state.badgeIdentifier(for: fixture.fileURL, at: now), FinderBadgeIdentifier.clean)
        XCTAssertEqual(fixture.state.badgeIdentifier(for: rootURL.appendingPathComponent("unknown.txt"), at: now),
                       FinderBadgeIdentifier.unknown)
        XCTAssertEqual(fixture.state.badgeIdentifier(for: rootURL.appendingPathComponent(".svn/wc.db"), at: now),
                       FinderBadgeIdentifier.none)
        // The timer can expire one root without rereading JSON or aging another.
        XCTAssertEqual(fixture.state.badgeIdentifier(for: fixture.fileURL, at: now.addingTimeInterval(2)),
                       FinderBadgeIdentifier.stale)
        XCTAssertEqual(fixture.state.badgeIdentifier(for: secondFile, at: now.addingTimeInterval(2)),
                       FinderBadgeIdentifier.clean)
        try fixture.writeBadges(.clean)
        fixture.state.reload()
        XCTAssertEqual(fixture.state.badgeIdentifier(for: fixture.fileURL, at: now), FinderBadgeIdentifier.stale)
        XCTAssertNil(fixture.state.directBadge(for: fixture.fileURL))
    }

    func testBadgeTrackerRepaintsRequestedPathsAndDropsClosedDirectories() {
        let root = RegisteredRoot(id: UUID(), path: "/tmp/tracked-copy", displayName: nil, enabled: true)
        let directory = URL(fileURLWithPath: root.path).appendingPathComponent("src")
        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.txt")
        let third = directory.appendingPathComponent("third.txt")
        var tracker = FinderBadgeTracker(maximumRequestedURLs: 2)
        tracker.observe(directory, roots: [root])
        for file in [first, second, third] {
            tracker.request(file, identifier: FinderBadgeIdentifier.clean, roots: [root])
        }
        XCTAssertEqual(tracker.requestedURLs, [second, third])
        XCTAssertEqual(tracker.directoryRequests(roots: [root]).count, 1)
        XCTAssertEqual(tracker.directoryRequests(roots: [root]).first?.itemPaths, [third.path, second.path])
        let updates = tracker.badgeUpdates { _ in FinderBadgeIdentifier.stale }
        XCTAssertEqual(updates.map(\.url), [second, third])
        XCTAssertTrue(tracker.badgeUpdates { _ in FinderBadgeIdentifier.stale }.isEmpty)
        tracker.stopObserving(URL(fileURLWithPath: directory.path, isDirectory: true))
        XCTAssertTrue(tracker.requestedURLs.isEmpty)
        XCTAssertTrue(tracker.directoryRequests(roots: [root]).isEmpty)
        tracker.observe(directory, roots: [root])
        tracker.request(first, identifier: FinderBadgeIdentifier.clean, roots: [root])
        tracker.pruneUnregistered(roots: [])
        XCTAssertTrue(tracker.requestedURLs.isEmpty)
        XCTAssertTrue(tracker.observedDirectories.isEmpty)
    }

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
