import Darwin
import Foundation
import XCTest
@testable import SvnDockFinderExtension

final class FinderBadgePresentationTests: XCTestCase {
    private let root = RegisteredRoot(
        id: UUID(), path: "/tmp/working-copy", displayName: nil, enabled: true
    )
    private let now = Date(timeIntervalSince1970: 1_777_777_777)

    func testDirectStateNeverFallsBackToAncestorDisplayBadge() {
        let directory = URL(fileURLWithPath: root.path + "/Sources")
        let loader = makeLoader(entries: [directory.path: .conflicted], direct: [directory.path: .clean])
        let state = SharedStateStore(container: loader)
        state.reload()
        XCTAssertEqual(state.badge(for: directory), .conflicted)
        XCTAssertEqual(state.directBadge(for: directory), .clean)
        XCTAssertEqual(state.badgeIdentifier(for: directory, at: now), FinderBadgeIdentifier.conflicted)

        loader.snapshot = snapshot(entries: [directory.path: .unversioned], direct: [:])
        state.reload()
        XCTAssertNil(state.directBadge(for: directory))
    }

    func testCleanRequiresFreshRootAndUnknownNeverBecomesGreen() {
        let file = URL(fileURLWithPath: root.path + "/File.swift")
        let loader = makeLoader(entries: [file.path: .clean], direct: [file.path: .clean])
        let state = SharedStateStore(container: loader)
        state.reload()
        XCTAssertEqual(state.badgeIdentifier(for: file, at: now), FinderBadgeIdentifier.clean)
        XCTAssertEqual(state.badgeIdentifier(for: file, at: now.addingTimeInterval(61)), FinderBadgeIdentifier.stale)
        XCTAssertEqual(state.badgeIdentifier(for: URL(fileURLWithPath: root.path + "/Unknown"), at: now),
                       FinderBadgeIdentifier.unknown)
        XCTAssertEqual(state.badgeIdentifier(for: URL(fileURLWithPath: root.path + "/.svn/entries"), at: now), "")
        XCTAssertEqual(state.badgeIdentifier(for: URL(fileURLWithPath: root.path + "-other/File"), at: now), "")
    }

    func testLegacySnapshotRemainsUnknownAndGlobalDateDoesNotRefreshAnotherRoot() throws {
        let file = URL(fileURLWithPath: root.path + "/File.swift")
        let legacy = BadgeSnapshotDocument(schemaVersion: 1, generatedAt: timestamp(now), entries: [file.path: .clean])
        let decoded = try JSONDecoder().decode(BadgeSnapshotDocument.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.directEntries)
        XCTAssertNil(decoded.perRootUpdatedAt)
        let loader = BadgeMemoryLoader(roots: [root], snapshot: decoded)
        let state = SharedStateStore(container: loader)
        state.reload()
        XCTAssertNil(state.directBadge(for: file))
        XCTAssertEqual(state.badgeIdentifier(for: file, at: now), FinderBadgeIdentifier.stale)

        loader.snapshot = BadgeSnapshotDocument(schemaVersion: 1, generatedAt: timestamp(now),
            entries: [file.path: .clean], directEntries: [file.path: .clean],
            perRootUpdatedAt: ["/tmp/another-working-copy": timestamp(now)])
        state.reload()
        XCTAssertEqual(state.badgeIdentifier(for: file, at: now), FinderBadgeIdentifier.stale)
        loader.roots = []
        state.reload()
        XCTAssertEqual(state.badgeIdentifier(for: file, at: now), "")
    }

    func testFreshnessHandlesTimestampVariantsBoundaryAndFutureClock() {
        XCTAssertTrue(FinderBadgeFreshness.isFresh(now.addingTimeInterval(-60), at: now))
        XCTAssertTrue(!FinderBadgeFreshness.isFresh(now.addingTimeInterval(-61), at: now))
        XCTAssertTrue(!FinderBadgeFreshness.isFresh(now.addingTimeInterval(6), at: now))
        XCTAssertTrue(!FinderBadgeFreshness.isFresh(nil, at: now))
        XCTAssertNil(FinderBadgeFreshness.date(from: "not-a-date"))
        XCTAssertEqual(FinderBadgeFreshness.date(from: "2026-05-03T03:09:37Z"), now)
        XCTAssertEqual(FinderBadgeFreshness.date(from: "2026-05-03T03:09:37.000Z"), now)
    }

    func testRepaintingOnlyUpdatesRequestedPathsAndClearsRemovedBadges() {
        let first = URL(fileURLWithPath: root.path + "/First")
        let second = URL(fileURLWithPath: root.path + "/Second")
        var tracker = FinderBadgeTracker()
        tracker.request(first, identifier: FinderBadgeIdentifier.clean, roots: [root])
        tracker.request(second, identifier: FinderBadgeIdentifier.modified, roots: [root])
        XCTAssertEqual(tracker.badgeUpdates { _ in FinderBadgeIdentifier.modified },
                       [.init(url: first, identifier: FinderBadgeIdentifier.modified)])
        XCTAssertTrue(tracker.badgeUpdates { _ in FinderBadgeIdentifier.modified }.isEmpty)
        XCTAssertEqual(tracker.badgeUpdates { _ in "" },
                       [.init(url: first, identifier: ""), .init(url: second, identifier: "")])
        tracker.pruneUnregistered(roots: [])
        XCTAssertTrue(tracker.requestedURLs.isEmpty)
        XCTAssertTrue(tracker.directoryRequests(roots: []).isEmpty)
    }

    func testRequestedPathCapDeduplicationAndDirectoryScope() {
        var tracker = FinderBadgeTracker(maximumRequestedURLs: 3)
        let files = (0..<4).map { URL(fileURLWithPath: root.path + "/Sources/File\($0)") }
        for file in files { tracker.request(file, identifier: "", roots: [root]) }
        tracker.request(files[3], identifier: "", roots: [root])
        tracker.request(URL(fileURLWithPath: root.path + "/.svn/entries"), identifier: "", roots: [root])
        tracker.request(URL(fileURLWithPath: "/tmp/outside/File"), identifier: "", roots: [root])
        XCTAssertEqual(tracker.requestedURLs, Array(files.suffix(3)))
        let requests = tracker.directoryRequests(roots: [root])
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.directoryPath, root.path + "/Sources")
        XCTAssertEqual(requests.first?.itemPaths, files.suffix(3).reversed().map(\.path))
        XCTAssertEqual(requests.first?.workingCopyID, root.id)
    }

    func testRecentDirectoryLimitAndEndObservationPreservesOtherVisibleDirectory() {
        var tracker = FinderBadgeTracker()
        let rootURL = URL(fileURLWithPath: root.path)
        let files = (0..<40).map { URL(fileURLWithPath: root.path + "/Directory\($0)/File") }
        for file in files { tracker.request(file, identifier: "", roots: [root]) }
        XCTAssertEqual(tracker.directoryRequests(roots: [root]).count, 32)
        XCTAssertEqual(tracker.directoryRequests(roots: [root]).first?.directoryPath,
                       files.last?.deletingLastPathComponent().path)
        let nestedDirectory = files[39].deletingLastPathComponent()
        tracker.observe(rootURL, roots: [root])
        tracker.observe(nestedDirectory, roots: [root])
        tracker.stopObserving(rootURL)
        XCTAssertEqual(tracker.requestedURLs, [files[39]])
        XCTAssertEqual(tracker.directoryRequests(roots: [root]).count, 1)
        tracker.stopObserving(nestedDirectory)
        XCTAssertTrue(tracker.requestedURLs.isEmpty)
        XCTAssertTrue(tracker.directoryRequests(roots: [root]).isEmpty)
    }

    func testRequestEncodingRespectsDirectoryItemAndByteBudgets() throws {
        let directories = (0..<40).map { index in
            FinderBadgeDirectoryRequest(workingCopyID: root.id, workingCopyRoot: root.path,
                directoryPath: root.path + "/Directory\(index)",
                itemPaths: (0..<100).map {
                    root.path + "/Directory\(index)/\($0)" + String(repeating: "长文件名", count: 40)
                })
        }
        let data = try FinderBadgeRequestDocument.encoded(id: UUID(), directories: directories, maximumBytes: 8_000)
        let document = try JSONDecoder().decode(FinderBadgeRequestDocument.self, from: data)
        XCTAssertTrue(data.count <= 8_000)
        XCTAssertTrue(document.directories.count <= 32)
        XCTAssertTrue(document.directories.reduce(0) { $0 + ($1.itemPaths?.count ?? 0) } <= 2_048)
        XCTAssertEqual(document.directories.first?.directoryPath, directories.first?.directoryPath)
        XCTAssertTrue(FinderBadgeFreshness.date(from: document.updatedAt) != nil)
    }

    func testSymbolSpecificationsGiveEachStateAColorShapeAndLabel() {
        let specs = FinderBadgeSymbolSpec.all
        XCTAssertEqual(Set(specs.map(\.identifier)).count, specs.count)
        for kind in BadgeKind.allCases {
            XCTAssertTrue(specs.contains { $0.identifier == kind.finderBadgeIdentifier })
        }
        let colors = Dictionary(uniqueKeysWithValues: specs.map { ($0.identifier, $0.color) })
        XCTAssertEqual(colors[FinderBadgeIdentifier.clean], .green)
        XCTAssertEqual(colors[FinderBadgeIdentifier.modified], .yellow)
        XCTAssertEqual(colors[FinderBadgeIdentifier.conflicted], .red)
        XCTAssertEqual(colors[FinderBadgeIdentifier.added], .blue)
        for id in [FinderBadgeIdentifier.unversioned, FinderBadgeIdentifier.ignored,
                   FinderBadgeIdentifier.stale, FinderBadgeIdentifier.unknown] {
            XCTAssertEqual(colors[id], .gray)
        }
        XCTAssertTrue(specs.allSatisfy { !$0.symbol.isEmpty && !$0.label.isEmpty })
        XCTAssertTrue(specs.first { $0.identifier == FinderBadgeIdentifier.clean }?.symbol
            != specs.first { $0.identifier == FinderBadgeIdentifier.stale }?.symbol)
    }

    #if SVNDOCK_LOCAL_SIGNED_BUILD
    func testRequestWriterUsesPrivatePermissionsAndStableInstanceFile() throws {
        let fixture = try ContainerFixture()
        defer { fixture.remove() }
        let requestID = UUID()
        let request = FinderBadgeDirectoryRequest(workingCopyID: root.id, workingCopyRoot: root.path,
                                                 directoryPath: root.path)
        try fixture.container.writeBadgeRequest(instanceID: requestID, directories: [request])
        let directory = fixture.directory.appendingPathComponent(SharedContainer.badgeRequestDirectoryName)
        let destination = directory.appendingPathComponent(requestID.uuidString.lowercased() + ".json")
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((attributes[.ownerAccountID] as? NSNumber)?.uint32Value, getuid())
        let document = try JSONDecoder().decode(FinderBadgeRequestDocument.self, from: Data(contentsOf: destination))
        XCTAssertEqual(document.id, requestID)
        XCTAssertEqual(document.directories, [FinderBadgeDirectoryRequest(
            workingCopyID: root.id, workingCopyRoot: root.path, directoryPath: root.path, itemPaths: []
        )])
        try fixture.container.writeBadgeRequest(instanceID: requestID, directories: [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path),
                       [requestID.uuidString.lowercased() + ".json"])
        let cleared = try JSONDecoder().decode(FinderBadgeRequestDocument.self, from: Data(contentsOf: destination))
        XCTAssertTrue(cleared.directories.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        do {
            try fixture.container.writeBadgeRequest(instanceID: requestID, directories: [])
            throw CocoaError(.fileWriteUnknown)
        } catch SharedContainerError.invalidBadgeRequestDirectory { }
    }

    func testRootLoaderFiltersDisabledAndCanonicalizesRoots() throws {
        let fixture = try ContainerFixture()
        defer { fixture.remove() }
        let disabled = RegisteredRoot(id: UUID(), path: root.path + "/Disabled", displayName: nil, enabled: false)
        let relative = RegisteredRoot(id: UUID(), path: "relative", displayName: nil, enabled: true)
        let alias = RegisteredRoot(id: root.id, path: root.path + "/Sources/..", displayName: nil, enabled: true)
        let data = try JSONEncoder().encode(RegisteredRootsDocument(schemaVersion: 1, roots: [disabled, relative, alias, root]))
        try data.write(to: fixture.container.registeredRootsURL!)
        XCTAssertEqual(try fixture.container.loadRegisteredRoots(), [root])
    }

    private final class ContainerFixture {
        let parent: URL
        let directory: URL
        let container: SharedContainer

        init() throws {
            parent = FileManager.default.temporaryDirectory.appendingPathComponent("FinderBadgeWriter-\(UUID())")
            directory = parent.appendingPathComponent("shared", isDirectory: true)
            let bundleURL = parent.appendingPathComponent("Fixture.bundle", isDirectory: true)
            let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "CFBundleIdentifier": "com.svndock.finder-tests.\(UUID())",
                "CFBundlePackageType": "BNDL",
                SharedContainer.localSharedDirectoryInfoKey: directory.path
            ]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            guard let bundle = Bundle(url: bundleURL) else { throw CocoaError(.fileReadCorruptFile) }
            container = SharedContainer(bundle: bundle)
        }

        func remove() { try? FileManager.default.removeItem(at: parent) }
    }
    #endif

    private func snapshot(entries: [String: BadgeKind], direct: [String: BadgeKind]) -> BadgeSnapshotDocument {
        BadgeSnapshotDocument(schemaVersion: 1, generatedAt: timestamp(now), entries: entries,
            directEntries: direct, perRootUpdatedAt: [root.path: timestamp(now)])
    }

    private func makeLoader(entries: [String: BadgeKind], direct: [String: BadgeKind]) -> BadgeMemoryLoader {
        BadgeMemoryLoader(roots: [root], snapshot: snapshot(entries: entries, direct: direct))
    }

    private func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

private final class BadgeMemoryLoader: SharedStateLoading {
    let registeredRootsURL: URL? = nil
    let badgeSnapshotURL: URL? = nil
    var roots: [RegisteredRoot]
    var snapshot: BadgeSnapshotDocument

    init(roots: [RegisteredRoot], snapshot: BadgeSnapshotDocument) {
        self.roots = roots
        self.snapshot = snapshot
    }

    func loadRegisteredRoots() throws -> [RegisteredRoot] { roots }
    func loadBadgeSnapshot() throws -> BadgeSnapshotDocument { snapshot }
}
