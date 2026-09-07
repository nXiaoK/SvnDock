import Foundation
import SvnDockCore

enum FinderBadgeRegressionChecks {
    static func run() async throws {
        try badgeDerivation()
        try await snapshotOwnershipAndFreshness()
        try await largeSnapshotsRemainReadable()
        try await requestsRemainBoundedAndRegistered()
        print("Finder badge core checks passed: exact states, folder summaries, bounded clean priority, per-root freshness, private requests and registration boundaries")
    }

    private static func badgeDerivation() throws {
        let copy = WorkingCopy(localPath: URL(fileURLWithPath: "/tmp/finder-badges"))
        let badges = FinderBadgeBuilder.build(from: [
            StatusEntry(path: ".", status: .normal),
            StatusEntry(path: "src", status: .normal),
            StatusEntry(path: "src/deep/file.txt", status: .modified),
            StatusEntry(path: "src/deep/conflict.txt", status: .normal, propertyStatus: .conflicted),
            StatusEntry(path: "src/clean.txt", status: .normal),
            StatusEntry(path: "loose.txt", status: .unversioned),
            StatusEntry(path: "cache", status: .ignored),
            StatusEntry(path: "unknown.txt", status: .unknown("new-client-status")),
            StatusEntry(path: "file-external.txt", status: .normal, isFileExternal: true),
            StatusEntry(path: "directory-external", status: .external),
            StatusEntry(path: "external/file.txt", status: .conflicted),
            StatusEntry(path: "../outside.txt", status: .modified)
        ], in: copy, excludingRoots: ["/tmp/finder-badges/external"])
        try check(badges.entries["/tmp/finder-badges/src/deep"] == .conflicted
                    && badges.entries["/tmp/finder-badges/src"] == .conflicted
                    && badges.entries["/tmp/finder-badges"] == .conflicted,
                  "conflicts aggregate through every versioned ancestor")
        try check(badges.directEntries["/tmp/finder-badges/src"] == .clean
                    && badges.directEntries["/tmp/finder-badges/src/deep"] == nil,
                  "summaries cannot turn clean/unknown directories into exact conflicts")
        try check(badges.directEntries["/tmp/finder-badges/loose.txt"] == .unversioned
                    && badges.directEntries["/tmp/finder-badges/cache"] == .ignored
                    && badges.directEntries["/tmp/finder-badges/src/clean.txt"] == .clean,
                  "ignored, unversioned and clean have separate authoritative states")
        try check(badges.entries["/tmp/finder-badges/unknown.txt"] == nil
                    && badges.entries["/tmp/finder-badges/external/file.txt"] == nil
                    && badges.entries["/tmp/finder-badges/file-external.txt"] == nil
                    && badges.entries["/tmp/finder-badges/directory-external"] == nil
                    && badges.entries["/tmp/outside.txt"] == nil,
                  "unknown states and foreign paths never acquire green or aggregate badges")
        let ignoredOnly = FinderBadgeBuilder.build(from: [StatusEntry(path: "cache", status: .ignored)], in: copy)
        try check(ignoredOnly.entries[copy.canonicalPath] == nil, "ignored items do not dirty their ancestors")

        let many = (0..<5_000).map { StatusEntry(path: "clean-\($0).txt", status: .normal) }
        let preferred = copy.localPath.appendingPathComponent("clean-4999.txt").path
        let bounded = FinderBadgeBuilder.build(from: many, in: copy, preferredPaths: [preferred])
        try check(bounded.directEntries.count == FinderBadgeBuilder.maximumCleanEntries
                    && bounded.directEntries[preferred] == .clean,
                  "green badges are bounded while actually visible items take priority")

        let builder = try SVNCommandBuilder(executableURL: URL(fileURLWithPath: "/usr/bin/svn"))
        let ordinary = try builder.makeInvocation(for: .status(SVNStatusOptions()), in: copy)
        try check(!ordinary.arguments.contains("--verbose"), "ordinary status stays sparse")
        let finder = try builder.makeInvocation(for: .status(SVNStatusOptions(
            includeIgnored: true, includeUnchanged: true, ignoreExternals: true, depth: .immediates, paths: ["src"])), in: copy)
        try check(finder.arguments.contains("--verbose") && finder.arguments.contains("--no-ignore")
                    && finder.arguments.contains("--ignore-externals") && finder.arguments.contains("immediates"),
                  "Finder status explicitly requests normal nodes within its directory scope")
        let legacy = Data("{\"showRemoteUpdates\":false,\"includeIgnored\":false}".utf8)
        let options = try JSONDecoder().decode(SVNStatusOptions.self, from: legacy)
        try check(!options.includeUnchanged && !options.ignoreExternals, "legacy status options retain sparse defaults")
    }

    private static func snapshotOwnershipAndFreshness() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("finder-badge-snapshot-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = try FinderSharedStore(directoryURL: temporary)
        let first = WorkingCopy(localPath: URL(fileURLWithPath: "/tmp/badge-first"))
        let second = WorkingCopy(localPath: URL(fileURLWithPath: "/tmp/badge-second"))
        let nested = WorkingCopy(localPath: URL(fileURLWithPath: "/tmp/badge-first/nested"))
        _ = try await store.register(first)
        _ = try await store.register(second)
        _ = try await store.register(nested)
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)
        let nestedPath = nested.localPath.appendingPathComponent("file.txt").path
        try await store.replaceBadgeEntries(forWorkingCopyID: first.id, underWorkingCopyRoot: first.canonicalPath,
            with: [first.canonicalPath: .conflicted], directEntries: [first.canonicalPath: .clean], updatedAt: firstDate)
        try await store.replaceBadgeEntries(forWorkingCopyID: nested.id, underWorkingCopyRoot: nested.canonicalPath,
            with: [nestedPath: .clean], directEntries: [nestedPath: .clean], updatedAt: firstDate)
        try await store.replaceBadgeEntries(forWorkingCopyID: second.id, underWorkingCopyRoot: second.canonicalPath,
            with: [second.canonicalPath: .clean], directEntries: [second.canonicalPath: .clean], updatedAt: secondDate)
        let fresh = try await store.loadBadgeSnapshot()
        try check(fresh.perRootUpdatedAt?[first.canonicalPath] == firstDate
                    && fresh.perRootUpdatedAt?[second.canonicalPath] == secondDate,
                  "refreshing a second root cannot refresh the first root's timestamp")
        try check(fresh.entries[first.canonicalPath] == .conflicted
                    && fresh.directEntries?[first.canonicalPath] == .clean,
                  "exact and display states survive the shared JSON contract independently")
        try await store.replaceBadgeEntries(forWorkingCopyID: first.id, underWorkingCopyRoot: first.canonicalPath,
            with: [:], directEntries: [:], updatedAt: secondDate)
        let sparse = try await store.loadBadgeSnapshot()
        try check(sparse.directEntries?[first.canonicalPath] == nil
                    && sparse.directEntries?[nestedPath] == .clean
                    && sparse.perRootUpdatedAt?[nested.canonicalPath] == firstDate,
                  "sparse replacement clears old green state but preserves nested ownership and freshness")
        _ = try await store.unregister(id: first.id)
        try await store.removeBadgeEntries(forUnregisteredWorkingCopyID: first.id, underWorkingCopyRoot: first.canonicalPath)
        let removed = try await store.loadBadgeSnapshot()
        try check(removed.perRootUpdatedAt?[first.canonicalPath] == nil
                    && removed.directEntries?[nestedPath] == .clean,
                  "unregister clears only the retired root's metadata")
    }

    private static func largeSnapshotsRemainReadable() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("finder-large-snapshot-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = try FinderSharedStore(directoryURL: temporary)
        let first = WorkingCopy(localPath: URL(fileURLWithPath: "/tmp/large-first"))
        let second = WorkingCopy(localPath: URL(fileURLWithPath: "/tmp/large-second"))
        _ = try await store.register(first)
        _ = try await store.register(second)
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)
        try await store.replaceBadgeEntries(forWorkingCopyID: first.id, underWorkingCopyRoot: first.canonicalPath,
            with: [first.canonicalPath: .modified], directEntries: [first.canonicalPath: .clean], updatedAt: firstDate)
        let longName = String(repeating: "目录\\\"", count: 15)
        let statuses = (0..<20_000).map { StatusEntry(path: "src/\(longName)-\($0).txt", status: .added) }
            + [StatusEntry(path: "src/conflict.txt", status: .conflicted), StatusEntry(path: "src", status: .normal)]
        let badges = FinderBadgeBuilder.build(from: statuses, in: second)
        try await store.replaceBadgeEntries(forWorkingCopyID: second.id, underWorkingCopyRoot: second.canonicalPath,
            with: badges.entries, directEntries: badges.directEntries, updatedAt: secondDate)
        let data = try Data(contentsOf: temporary.appendingPathComponent(FinderSharedSchema.badgeSnapshotFileName))
        let snapshot = try await store.loadBadgeSnapshot()
        try check(data.count <= FinderSharedSchema.maximumBadgeSnapshotBytes
                    && snapshot.entries.count < badges.entries.count,
                  "large Unicode/escaped paths are compacted below the Finder reader's actual byte limit")
        try check(snapshot.entries[first.canonicalPath] == .modified
                    && snapshot.directEntries?[first.canonicalPath] == .clean
                    && snapshot.perRootUpdatedAt?[first.canonicalPath] == firstDate,
                  "compacting another root preserves the first root's summary, exact state and freshness")
        try check(snapshot.entries[second.canonicalPath] == .conflicted
                    && snapshot.entries[second.canonicalPath + "/src"] == .conflicted
                    && snapshot.directEntries?[second.canonicalPath + "/src"] == .clean
                    && snapshot.directEntries?[second.canonicalPath + "/src/conflict.txt"] == .conflicted
                    && snapshot.perRootUpdatedAt?[second.canonicalPath] == secondDate,
                  "conflicts and full-tree summaries survive without inventing exact directory conflicts")
        try check(snapshot.entryOwners?.allSatisfy { snapshot.entries[$0.key] != nil } == true
                    && snapshot.directEntries?.allSatisfy { snapshot.entries[$0.key] != nil } == true,
                  "ownership and direct-state metadata are compacted with their matching display entries")
        let omitted = badges.entries.keys.first { snapshot.entries[$0] == nil }
        try check(omitted != nil && snapshot.directEntries?[omitted!] == nil,
                  "omitted badges remain unknown, never clean or eligible through an ancestor summary")
    }

    private static func requestsRemainBoundedAndRegistered() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("finder-badge-requests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let directory = temporary.appendingPathComponent(FinderBadgeRefreshRequestStore.directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = try FinderBadgeRefreshRequestStore(baseDirectoryURL: temporary)
        let root = RegisteredRoot(id: UUID(), path: "/tmp/request-wc")
        let nested = RegisteredRoot(id: UUID(), path: "/tmp/request-wc/nested")
        let disabled = RegisteredRoot(id: UUID(), path: "/tmp/disabled-wc", enabled: false)
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let valid = FinderBadgeRefreshDirectory(workingCopyID: root.id, workingCopyRoot: root.path,
            directoryPath: root.path + "/src", itemPaths: [root.path + "/src/文本@.txt", "/tmp/outside", root.path + "/src/deep/file.txt"])
        let payload = FinderBadgeRefreshRequest(id: UUID(), updatedAt: now, directories: [valid,
            FinderBadgeRefreshDirectory(workingCopyID: root.id, workingCopyRoot: root.path, directoryPath: nested.path),
            FinderBadgeRefreshDirectory(workingCopyID: disabled.id, workingCopyRoot: disabled.path, directoryPath: disabled.path),
            FinderBadgeRefreshDirectory(workingCopyID: root.id, workingCopyRoot: root.path, directoryPath: "/tmp/request-wc-other")
        ])
        try write(payload, in: directory)
        try write(FinderBadgeRefreshRequest(id: UUID(), updatedAt: now.addingTimeInterval(-31), directories: [valid]), in: directory)
        try write(FinderBadgeRefreshRequest(id: UUID(), updatedAt: now.addingTimeInterval(60), directories: [valid]), in: directory)
        try write(FinderBadgeRefreshRequest(id: UUID(), updatedAt: now, directories: Array(repeating: valid, count: 33)), in: directory)
        let insecure = FinderBadgeRefreshRequest(id: UUID(), updatedAt: now, directories: [valid])
        let insecureURL = try write(insecure, in: directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: insecureURL.path)
        let link = directory.appendingPathComponent(UUID().uuidString.lowercased() + ".json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: insecureURL)
        let result = try await store.activeDirectories(registeredRoots: [root, nested, disabled], now: now)
        try check(result.count == 1 && result[0].directoryPath == valid.directoryPath
                    && result[0].itemPaths == [root.path + "/src/文本@.txt"],
                  "request reads enforce privacy, TTL, size scope, deepest root and direct-child preference")
        let expired = try await store.activeDirectories(registeredRoots: [root, nested, disabled], now: now.addingTimeInterval(31))
        try check(expired.isEmpty, "dead Finder processes expire without persistent observation work")

        for _ in 0..<300 {
            let old = FinderBadgeRefreshRequest(id: UUID(), updatedAt: now.addingTimeInterval(-120), directories: [valid])
            let oldURL = try write(old, in: directory)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-120)], ofItemAtPath: oldURL.path)
        }
        let afterRestarts = try await store.activeDirectories(registeredRoots: [root, nested, disabled], now: now)
        try check(afterRestarts.count == 1, "hundreds of expired process files cannot hide a current Finder request")
        for index in 0..<12 {
            let observed = FinderBadgeRefreshDirectory(workingCopyID: root.id, workingCopyRoot: root.path,
                directoryPath: root.path + "/window-\(index)")
            try write(FinderBadgeRefreshRequest(id: UUID(), updatedAt: now.addingTimeInterval(1), directories: [observed]), in: directory)
        }
        let bounded = try await store.activeDirectories(registeredRoots: [root, nested, disabled], now: now)
        try check(bounded.count == FinderBadgeRefreshRequestStore.maximumActiveProcesses,
                  "at most ten live process requests contribute observation work")
    }

    @discardableResult
    private static func write(_ request: FinderBadgeRefreshRequest, in directory: URL) throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = directory.appendingPathComponent(request.id.uuidString.lowercased() + ".json")
        try encoder.encode(request).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw FinderBadgeCheckFailure(message: message) }
    }
}

private struct FinderBadgeCheckFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
