import Darwin
import Foundation

#if SVNDOCK_LOCAL_SIGNED_BUILD && SVNDOCK_PORTABLE_SIGNED_BUILD
#error("Choose either a current-account local build or a portable ad-hoc build, not both.")
#endif

public enum FinderSharedSchema {
    public static let currentVersion = 1
    public static let registeredRootsFileName = "registered-roots.json"
    public static let badgeSnapshotFileName = "badge-snapshot.json"
    public static let commandQueueDirectoryName = "command-queue"
}

public struct RegisteredRoot: Codable, Hashable, Sendable {
    public let id: UUID
    public let path: String
    public let displayName: String?
    public let enabled: Bool

    public init(id: UUID, path: String, displayName: String? = nil, enabled: Bool = true) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.enabled = enabled
    }

    public init(_ workingCopy: WorkingCopy) {
        self.init(
            id: workingCopy.id,
            path: workingCopy.localPath.standardizedFileURL.path,
            displayName: workingCopy.name,
            enabled: workingCopy.isEnabled
        )
    }
}

public struct RegisteredRootsDocument: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let roots: [RegisteredRoot]

    public init(
        schemaVersion: Int = FinderSharedSchema.currentVersion,
        roots: [RegisteredRoot]
    ) {
        self.schemaVersion = schemaVersion
        self.roots = roots
    }
}

public enum BadgeKind: String, Codable, CaseIterable, Hashable, Sendable {
    case modified
    case added
    case deleted
    case conflicted
    case unversioned
    case missing
    case replaced
    case ignored
    case clean

    public init(statusEntry: StatusEntry) {
        if statusEntry.isTreeConflicted
            || statusEntry.status == .conflicted
            || statusEntry.propertyStatus == .conflicted {
            self = .conflicted
            return
        }

        switch statusEntry.status {
        case .modified, .merged, .incomplete, .obstructed:
            self = .modified
        case .added:
            self = .added
        case .deleted:
            self = .deleted
        case .conflicted:
            self = .conflicted
        case .unversioned:
            self = .unversioned
        case .missing:
            self = .missing
        case .replaced:
            self = .replaced
        case .ignored:
            self = .ignored
        case .external, .none, .normal, .unknown:
            self = statusEntry.propertyStatus.isLocalChange ? .modified : .clean
        }
    }
}

public struct BadgeSnapshot: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    /// Keys are absolute, standardized filesystem paths.
    public let entries: [String: BadgeKind]
    /// Internal ownership metadata used by App/Agent writers. Older Finder
    /// extensions ignore this key, and older snapshots decode it as `nil`.
    /// Keeping it in the same atomic document as `entries` prevents a delayed
    /// cleanup for an unregistered nested working copy from deleting badges a
    /// live parent has since refreshed.
    public let entryOwners: [String: UUID]?
    /// Exact SVN node states; `entries` may instead show descendant summaries.
    public let directEntries: [String: BadgeKind]?
    /// A refresh of one root must never make another root appear fresh.
    public let perRootUpdatedAt: [String: Date]?

    public init(
        schemaVersion: Int = FinderSharedSchema.currentVersion,
        generatedAt: Date = Date(),
        entries: [String: BadgeKind],
        entryOwners: [String: UUID]? = nil,
        directEntries: [String: BadgeKind]? = nil,
        perRootUpdatedAt: [String: Date]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.entries = entries
        self.entryOwners = entryOwners
        self.directEntries = directEntries
        self.perRootUpdatedAt = perRootUpdatedAt
    }
}

public enum FinderCommandKind: String, Codable, CaseIterable, Hashable, Sendable {
    case openApp
    case refresh
    case update
    case commit
    case diff
    case add
    case revert
    case cleanup
    case log
    case resolve
    case copyRepositoryURL
    case ignoreName
    case ignoreExtension
}

public struct FinderCommand: Codable, Identifiable, Hashable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let kind: FinderCommandKind
    public let paths: [String]
    public let workingCopyRoot: String
    public let createdAt: Date
    public let source: String

    public init(
        schemaVersion: Int = FinderSharedSchema.currentVersion,
        id: UUID = UUID(),
        kind: FinderCommandKind,
        paths: [String],
        workingCopyRoot: String,
        createdAt: Date = Date(),
        source: String = "finder-extension"
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.kind = kind
        self.paths = paths
        self.workingCopyRoot = workingCopyRoot
        self.createdAt = createdAt
        self.source = source
    }
}

public enum FinderSharedStoreError: Error, LocalizedError, Equatable, Sendable {
    case directoryIsNotAbsoluteFileURL
    case appGroupContainerUnavailable(String)
    case invalidLocalSharedDirectory(String)
    case invalidPortableAccountDirectory
    case pathIsNotAbsolute(String)
    case badgePathOutsideWorkingCopy(path: String, root: String)
    case badgeRootNotRegistered(String)
    case badgeOwnerWithoutEntry(String)
    case cannotLockBadgeSnapshot(Int32)
    case unsafeBadgeSnapshotLock
    case commandIdentifierMismatch(expected: UUID, actual: UUID)
    case invalidCommandFile(String)
    case unsupportedSchemaVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .directoryIsNotAbsoluteFileURL:
            return "The Finder shared-store directory must be an absolute file URL."
        case let .appGroupContainerUnavailable(identifier):
            return "The App Group container is unavailable: \(identifier)"
        case let .invalidLocalSharedDirectory(key):
            return "The local signed build is missing a valid absolute \(key) path."
        case .invalidPortableAccountDirectory:
            return "Unable to resolve the signed-in account's private directory. Run SvnDock as a regular desktop account, not as root or through sudo."
        case let .pathIsNotAbsolute(path):
            return "Finder shared data contains a non-absolute path: \(path)"
        case let .badgePathOutsideWorkingCopy(path, root):
            return "Finder badge path \(path) is outside working copy \(root)"
        case let .badgeRootNotRegistered(root):
            return "Finder badges cannot be published for an unregistered working copy: \(root)"
        case let .badgeOwnerWithoutEntry(path):
            return "Finder badge ownership has no matching entry: \(path)"
        case let .cannotLockBadgeSnapshot(code):
            return "Unable to lock the Finder badge snapshot (errno \(code))"
        case .unsafeBadgeSnapshotLock:
            return "The Finder badge snapshot lock is not a safe private regular file."
        case let .commandIdentifierMismatch(expected, actual):
            return "Finder command identifier mismatch: expected \(expected), found \(actual)"
        case let .invalidCommandFile(fileName):
            return "Finder command is not a regular queue file: \(fileName)"
        case let .unsupportedSchemaVersion(version):
            return "Unsupported Finder shared-data schema version: \(version)"
        }
    }
}

public enum FinderSharedStoreLocation {
    public static let localSharedDirectoryInfoKey = "SvnDockLocalSharedDirectory"

    /// Resolves a shared directory for both the containing app and Finder Sync
    /// extension. The App Group identifier comes from the targets' entitlements.
    public static func appGroupDirectory(
        groupIdentifier: String,
        subdirectory: String = "Library/Application Support/SvnDock"
    ) throws -> URL {
        #if os(macOS)
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier
        ) else {
            throw FinderSharedStoreError.appGroupContainerUnavailable(groupIdentifier)
        }
        return container.appendingPathComponent(subdirectory, isDirectory: true)
        #else
        throw FinderSharedStoreError.appGroupContainerUnavailable(groupIdentifier)
        #endif
    }

    #if SVNDOCK_LOCAL_SIGNED_BUILD
    /// Resolves the shared directory sealed into a locally signed build.
    /// Production builds do not compile this fallback API.
    public static func localSignedDirectory(bundle: Bundle = .main) throws -> URL {
        let key = localSharedDirectoryInfoKey
        guard let configured = (bundle.object(
            forInfoDictionaryKey: key
        ) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        configured.hasPrefix("/"),
        !configured.contains("$(") else {
            throw FinderSharedStoreError.invalidLocalSharedDirectory(key)
        }

        return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
    }
    #endif

    #if SVNDOCK_PORTABLE_SIGNED_BUILD
    /// Account-independent ad-hoc distribution. Read the account database,
    /// never environment variables or a sandbox container's synthetic home.
    public static func portableSignedDirectory() throws -> URL {
        let realUserID = getuid()
        let effectiveUserID = geteuid()
        guard realUserID != 0, realUserID == effectiveUserID else {
            throw FinderSharedStoreError.invalidPortableAccountDirectory
        }
        var account = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 64 * 1_024)
        let accountHome: String? = buffer.withUnsafeMutableBufferPointer { storage in
            guard getpwuid_r(realUserID, &account, storage.baseAddress, storage.count, &result) == 0,
                  let home = result?.pointee.pw_dir else { return nil }
            return String(cString: home)
        }
        return try portableSignedDirectory(accountHome: accountHome, realUserID: realUserID, effectiveUserID: effectiveUserID)
    }

    // Internal seam for testing two account homes without changing either
    // process identity or environment, and without writing to real user data.
    static func portableSignedDirectory(accountHome: String?, realUserID: uid_t, effectiveUserID: uid_t) throws -> URL {
        guard realUserID != 0, realUserID == effectiveUserID,
              let accountHome, accountHome.hasPrefix("/"), !accountHome.contains("\0") else {
            throw FinderSharedStoreError.invalidPortableAccountDirectory
        }
        let home = URL(fileURLWithPath: accountHome, isDirectory: true).standardizedFileURL
        guard home.path != "/", home.path != "/var/empty", home.path != "/dev/null" else {
            throw FinderSharedStoreError.invalidPortableAccountDirectory
        }
        return home.appendingPathComponent("Library/Application Support/SvnDock", isDirectory: true)
    }
    #endif
}

/// Atomic JSON persistence shared by the app, background agent and Finder Sync
/// extension through an App Group container.
///
/// Actor isolation serializes writers in one process. `Data.write(.atomic)`
/// ensures readers in another process observe either the old complete document
/// or the new complete document, never a partially written JSON file.
public actor FinderSharedStore {
    private static let maximumCommandFileSize = 256 * 1_024

    public nonisolated let directoryURL: URL

    public init(directoryURL: URL) throws {
        guard directoryURL.isFileURL, directoryURL.path.hasPrefix("/") else {
            throw FinderSharedStoreError.directoryIsNotAbsoluteFileURL
        }
        self.directoryURL = directoryURL.standardizedFileURL
    }

    public func writeRegisteredRoots(_ workingCopies: [WorkingCopy]) throws {
        try writeRegisteredRoots(RegisteredRootsDocument(roots: workingCopies.map(RegisteredRoot.init)))
    }

    public func writeRegisteredRoots(_ document: RegisteredRootsDocument) throws {
        try validateSchema(document.schemaVersion)
        try validate(document.roots)
        try ensureBaseDirectory()
        // Registry ownership changes and badge mutations share one
        // cross-process lock. A stale Agent cannot validate an old UUID and
        // publish after the App has replaced that registration at the same
        // path.
        try withBadgeSnapshotLock {
            try writeRegisteredRootsUnlocked(document)
        }
    }

    @discardableResult
    public func register(_ workingCopy: WorkingCopy) throws -> RegisteredRootsDocument {
        let registered = RegisteredRoot(workingCopy)
        try ensureBaseDirectory()
        return try withBadgeSnapshotLock {
            var roots = try loadRegisteredRootsUnlocked().roots
            roots.removeAll {
                $0.id == registered.id ||
                URL(fileURLWithPath: $0.path).standardizedFileURL.path == registered.path
            }
            roots.append(registered)
            roots.sort {
                ($0.displayName ?? $0.path).localizedStandardCompare($1.displayName ?? $1.path)
                    == .orderedAscending
            }
            let document = RegisteredRootsDocument(roots: roots)
            try writeRegisteredRootsUnlocked(document)
            return document
        }
    }

    @discardableResult
    public func unregister(id: UUID) throws -> RegisteredRootsDocument {
        try ensureBaseDirectory()
        return try withBadgeSnapshotLock {
            var roots = try loadRegisteredRootsUnlocked().roots
            roots.removeAll { $0.id == id }
            let document = RegisteredRootsDocument(roots: roots)
            try writeRegisteredRootsUnlocked(document)
            return document
        }
    }

    public func loadRegisteredRoots() throws -> RegisteredRootsDocument {
        try loadRegisteredRootsUnlocked()
    }

    private func loadRegisteredRootsUnlocked() throws -> RegisteredRootsDocument {
        guard FileManager.default.fileExists(atPath: registeredRootsURL.path) else {
            return RegisteredRootsDocument(roots: [])
        }
        let document = try decode(RegisteredRootsDocument.self, from: registeredRootsURL)
        try validateSchema(document.schemaVersion)
        try validate(document.roots)
        return document
    }

    public func writeBadgeSnapshot(_ snapshot: BadgeSnapshot) throws {
        try validateSchema(snapshot.schemaVersion)
        for path in snapshot.entries.keys {
            try validateAbsolute(path)
        }
        for path in snapshot.entryOwners?.keys ?? Dictionary<String, UUID>().keys {
            try validateAbsolute(path)
            guard snapshot.entries[path] != nil else {
                throw FinderSharedStoreError.badgeOwnerWithoutEntry(path)
            }
        }
        try validateBadgeMetadata(snapshot)
        try ensureBaseDirectory()
        try withBadgeSnapshotLock {
            try writeBadgeSnapshotUnlocked(snapshot)
        }
    }

    /// Replaces exactly one working copy's badge slice while holding a
    /// cross-process lock. App and Agent may refresh different roots at the
    /// same time without losing each other's entries.
    public func replaceBadgeEntries(
        forWorkingCopyID workingCopyID: UUID,
        underWorkingCopyRoot rootPath: String,
        with replacement: [String: BadgeKind],
        directEntries: [String: BadgeKind]? = nil,
        updatedAt: Date = Date()
    ) throws {
        try mutateBadgeEntries(
            underWorkingCopyRoot: rootPath,
            replacement: replacement,
            directReplacement: directEntries,
            updatedAt: updatedAt,
            mode: .registered(id: workingCopyID)
        )
    }

    /// Removes a former working copy's slice only if no currently registered
    /// working copy owns the same path. This prevents a delayed unregister
    /// cleanup from erasing badges belonging to a newly registered UUID.
    public func removeBadgeEntries(
        forUnregisteredWorkingCopyID workingCopyID: UUID,
        underWorkingCopyRoot rootPath: String
    ) throws {
        try mutateBadgeEntries(
            underWorkingCopyRoot: rootPath,
            replacement: [:],
            directReplacement: nil,
            updatedAt: Date(),
            mode: .unregistered(id: workingCopyID)
        )
    }

    private enum BadgeMutationMode {
        case registered(id: UUID)
        case unregistered(id: UUID)
    }

    private func mutateBadgeEntries(
        underWorkingCopyRoot rootPath: String,
        replacement: [String: BadgeKind],
        directReplacement: [String: BadgeKind]?,
        updatedAt: Date,
        mode: BadgeMutationMode
    ) throws {
        try validateAbsolute(rootPath)
        let standardizedRoot = URL(
            fileURLWithPath: rootPath,
            isDirectory: true
        ).standardizedFileURL.path

        var standardizedReplacement: [String: BadgeKind] = [:]
        standardizedReplacement.reserveCapacity(replacement.count)
        for (path, badge) in replacement {
            try validateAbsolute(path)
            let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            guard Self.path(standardizedPath, isInside: standardizedRoot) else {
                throw FinderSharedStoreError.badgePathOutsideWorkingCopy(
                    path: standardizedPath,
                    root: standardizedRoot
                )
            }
            standardizedReplacement[standardizedPath] = badge
        }
        var standardizedDirect: [String: BadgeKind] = [:]
        for (path, badge) in directReplacement ?? [:] {
            try validateAbsolute(path)
            let path = URL(fileURLWithPath: path).standardizedFileURL.path
            guard standardizedReplacement[path] != nil else {
                throw FinderSharedStoreError.badgeOwnerWithoutEntry(path)
            }
            standardizedDirect[path] = badge
        }

        try ensureBaseDirectory()
        try withBadgeSnapshotLock {
            let enabledRoots = try loadRegisteredRootsUnlocked().roots
                .filter(\.enabled)
                .map {
                    (
                        id: $0.id,
                        path: URL(
                            fileURLWithPath: $0.path,
                            isDirectory: true
                        ).standardizedFileURL.path
                    )
                }
            switch mode {
            case let .registered(id):
                guard enabledRoots.contains(where: {
                    $0.id == id && $0.path == standardizedRoot
                }) else {
                    throw FinderSharedStoreError.badgeRootNotRegistered(standardizedRoot)
                }
            case .unregistered:
                // Ownership is evaluated below. Even when a new UUID now owns
                // this exact path, entries tagged with the retired UUID can be
                // removed without touching the replacement's newer entries.
                break
            }
            let nestedRoots = enabledRoots
                .filter {
                    $0.path != standardizedRoot
                        && Self.path($0.path, isInside: standardizedRoot)
                }
            var entries: [String: BadgeKind]
            var owners: [String: UUID]
            var direct: [String: BadgeKind]
            var updatedByRoot: [String: Date]
            if FileManager.default.fileExists(atPath: badgeSnapshotURL.path) {
                let snapshot = try decode(BadgeSnapshot.self, from: badgeSnapshotURL)
                try validateSchema(snapshot.schemaVersion)
                entries = snapshot.entries
                owners = snapshot.entryOwners ?? [:]
                direct = snapshot.directEntries ?? [:]
                updatedByRoot = snapshot.perRootUpdatedAt ?? [:]
                try validateBadgeMetadata(snapshot)
                for path in entries.keys {
                    try validateAbsolute(path)
                }
                for path in owners.keys {
                    try validateAbsolute(path)
                    guard entries[path] != nil else {
                        throw FinderSharedStoreError.badgeOwnerWithoutEntry(path)
                    }
                }
            } else {
                entries = [:]
                owners = [:]
                direct = [:]
                updatedByRoot = [:]
            }

            switch mode {
            case let .registered(id):
                // A status refresh is authoritative for this root except for
                // independently registered nested working copies.
                entries = entries.filter { path, _ in
                    !Self.path(path, isInside: standardizedRoot)
                        || nestedRoots.contains(where: {
                            Self.path(path, isInside: $0.path)
                        })
                }
                owners = owners.filter { entries[$0.key] != nil }
                direct = direct.filter { entries[$0.key] != nil }
                let ownedReplacement = standardizedReplacement.filter { path, _ in
                    !nestedRoots.contains(where: {
                        Self.path(path, isInside: $0.path)
                    })
                }
                entries.merge(ownedReplacement) { _, replacement in replacement }
                for path in ownedReplacement.keys {
                    owners[path] = id
                    // A normal sparse App refresh intentionally drops cached
                    // green nodes until the next observed-directory refresh.
                    direct[path] = standardizedDirect[path]
                }
                updatedByRoot[standardizedRoot] = updatedAt

            case let .unregistered(id):
                // Remove only entries that still belong to the retired UUID.
                // For legacy ownerless snapshots, delete a path only when no
                // live registered root can own it; this fails safe during
                // migration and a later live-root refresh removes any stale
                // visual state.
                entries = entries.filter { path, _ in
                    guard Self.path(path, isInside: standardizedRoot) else {
                        return true
                    }
                    if let owner = owners[path] {
                        return owner != id
                    }
                    return enabledRoots.contains(where: {
                        Self.path(path, isInside: $0.path)
                    })
                }
                owners = owners.filter { entries[$0.key] != nil }
                direct = direct.filter { entries[$0.key] != nil }
                if !enabledRoots.contains(where: { $0.path == standardizedRoot }) {
                    updatedByRoot.removeValue(forKey: standardizedRoot)
                }
            }

            try writeBadgeSnapshotUnlocked(BadgeSnapshot(entries: entries, entryOwners: owners,
                directEntries: direct, perRootUpdatedAt: updatedByRoot))
        }
    }

    public func loadBadgeSnapshot() throws -> BadgeSnapshot {
        guard FileManager.default.fileExists(atPath: badgeSnapshotURL.path) else {
            return BadgeSnapshot(entries: [:])
        }
        let snapshot = try decode(BadgeSnapshot.self, from: badgeSnapshotURL)
        try validateSchema(snapshot.schemaVersion)
        for path in snapshot.entries.keys {
            try validateAbsolute(path)
        }
        for path in snapshot.entryOwners?.keys ?? Dictionary<String, UUID>().keys {
            try validateAbsolute(path)
            guard snapshot.entries[path] != nil else {
                throw FinderSharedStoreError.badgeOwnerWithoutEntry(path)
            }
        }
        try validateBadgeMetadata(snapshot)
        return snapshot
    }

    private func validateBadgeMetadata(_ snapshot: BadgeSnapshot) throws {
        for path in snapshot.directEntries?.keys ?? Dictionary<String, BadgeKind>().keys {
            try validateAbsolute(path)
            guard snapshot.entries[path] != nil else { throw FinderSharedStoreError.badgeOwnerWithoutEntry(path) }
        }
        for path in snapshot.perRootUpdatedAt?.keys ?? Dictionary<String, Date>().keys {
            try validateAbsolute(path)
        }
    }

    private func writeBadgeSnapshotUnlocked(_ snapshot: BadgeSnapshot) throws {
        let data = try encode(snapshot)
        // Finder's reader rejects larger documents. Preserve the previous
        // snapshot and its timestamps instead of publishing unreadable state.
        guard data.count <= 8 * 1_024 * 1_024 else { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: badgeSnapshotURL, options: .atomic)
    }

    /// Adds one immutable command file. A UUID filename avoids cross-process
    /// last-writer-wins races that a single queue JSON document would have.
    @discardableResult
    public func enqueue(_ command: FinderCommand) throws -> URL {
        try validateSchema(command.schemaVersion)
        try validateAbsolute(command.workingCopyRoot)
        for path in command.paths {
            try validateAbsolute(path)
        }

        try ensureCommandQueueDirectory()
        let destination = commandQueueURL
            .appendingPathComponent(command.id.uuidString.lowercased(), isDirectory: false)
            .appendingPathExtension("json")
        try encode(command).write(to: destination, options: .atomic)
        return destination
    }

    public func loadCommands() throws -> [FinderCommand] {
        guard FileManager.default.fileExists(atPath: commandQueueURL.path) else {
            return []
        }

        let urls = try FileManager.default.contentsOfDirectory(
            at: commandQueueURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )

        return urls
            .compactMap { url -> FinderCommand? in
                guard url.pathExtension == "json",
                      let expectedID = UUID(
                          uuidString: url.deletingPathExtension().lastPathComponent
                      ),
                      let values = try? url.resourceValues(
                          forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                      ),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      let command = try? decodeCommand(from: url),
                      command.schemaVersion == FinderSharedSchema.currentVersion,
                      command.id == expectedID else {
                    return nil
                }
                return command
            }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.createdAt < rhs.createdAt
            }
    }

    /// Loads only the queue item named by `id`.
    ///
    /// URL activation carries this opaque identifier, so decoding a single
    /// file prevents an unrelated malformed queue item from blocking the
    /// requested Finder action.
    public func loadCommand(id: UUID) throws -> FinderCommand? {
        let lowercasedURL = commandQueueURL
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: false)
            .appendingPathExtension("json")
        let uppercasedURL = commandQueueURL
            .appendingPathComponent(id.uuidString.uppercased(), isDirectory: false)
            .appendingPathExtension("json")

        let url: URL
        if FileManager.default.fileExists(atPath: lowercasedURL.path) {
            url = lowercasedURL
        } else if FileManager.default.fileExists(atPath: uppercasedURL.path) {
            url = uppercasedURL
        } else {
            return nil
        }

        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw FinderSharedStoreError.invalidCommandFile(url.lastPathComponent)
        }

        let command = try decodeCommand(from: url)
        try validateSchema(command.schemaVersion)
        guard command.id == id else {
            throw FinderSharedStoreError.commandIdentifierMismatch(
                expected: id,
                actual: command.id
            )
        }
        return command
    }

    public func removeCommand(id: UUID) throws {
        let lowercasedURL = commandQueueURL
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: false)
            .appendingPathExtension("json")
        let uppercasedURL = commandQueueURL
            .appendingPathComponent(id.uuidString.uppercased(), isDirectory: false)
            .appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: lowercasedURL.path) {
            try FileManager.default.removeItem(at: lowercasedURL)
        } else if FileManager.default.fileExists(atPath: uppercasedURL.path) {
            try FileManager.default.removeItem(at: uppercasedURL)
        }
    }

    private var registeredRootsURL: URL {
        directoryURL.appendingPathComponent(FinderSharedSchema.registeredRootsFileName)
    }

    private var badgeSnapshotURL: URL {
        directoryURL.appendingPathComponent(FinderSharedSchema.badgeSnapshotFileName)
    }

    private var badgeSnapshotLockURL: URL {
        directoryURL.appendingPathComponent("badge-snapshot.lock", isDirectory: false)
    }

    private var commandQueueURL: URL {
        directoryURL.appendingPathComponent(
            FinderSharedSchema.commandQueueDirectoryName,
            isDirectory: true
        )
    }

    private func ensureBaseDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    private func ensureCommandQueueDirectory() throws {
        try ensureBaseDirectory()
        try FileManager.default.createDirectory(
            at: commandQueueURL,
            withIntermediateDirectories: true
        )
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(FinderSharedDateCoding.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = FinderSharedDateCoding.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO-8601 date"
                )
            }
            return date
        }
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func decodeCommand(from url: URL) throws -> FinderCommand {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber,
           size.intValue > Self.maximumCommandFileSize {
            throw CocoaError(.fileReadTooLarge)
        }
        return try decode(FinderCommand.self, from: url)
    }

    private func validate(_ roots: [RegisteredRoot]) throws {
        try validateSchema(FinderSharedSchema.currentVersion)
        for root in roots {
            try validateAbsolute(root.path)
        }
    }

    private func writeRegisteredRootsUnlocked(_ document: RegisteredRootsDocument) throws {
        try encode(document).write(to: registeredRootsURL, options: .atomic)
    }

    private func validateSchema(_ version: Int) throws {
        guard version == FinderSharedSchema.currentVersion else {
            throw FinderSharedStoreError.unsupportedSchemaVersion(version)
        }
    }

    private func validateAbsolute(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw FinderSharedStoreError.pathIsNotAbsolute(path)
        }
    }

    private func withBadgeSnapshotLock<Result>(_ operation: () throws -> Result) throws -> Result {
        let descriptor = open(
            badgeSnapshotLockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw FinderSharedStoreError.cannotLockBadgeSnapshot(errno)
        }
        defer { _ = close(descriptor) }

        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_uid == geteuid(),
              attributes.st_nlink == 1,
              (attributes.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              fchmod(descriptor, 0o600) == 0 else {
            throw FinderSharedStoreError.unsafeBadgeSnapshotLock
        }

        while svnDockFlock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw FinderSharedStoreError.cannotLockBadgeSnapshot(errno)
        }
        defer { _ = svnDockFlock(descriptor, LOCK_UN) }
        return try operation()
    }

    private static func path(_ candidate: String, isInside root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

private enum FinderSharedDateCoding {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }

        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: string)
    }
}
