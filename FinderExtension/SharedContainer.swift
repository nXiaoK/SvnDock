import Foundation

enum SharedContainerError: LocalizedError {
    case invalidApplicationGroupConfiguration
    case invalidLocalSharedDirectoryConfiguration
    case missingApplicationGroup(String)
    case unsupportedSchema(file: String, version: Int)
    case invalidRootDocument
    case cannotCreateQueue(Error)
    case cannotEncodeRequest(Error)
    case cannotWriteRequest(Error)

    var errorDescription: String? {
        switch self {
        case .invalidApplicationGroupConfiguration:
            return "The Release build is missing a valid SvnDockAppGroupIdentifier."
        case .invalidLocalSharedDirectoryConfiguration:
            return "The local signed build is missing a valid absolute SvnDockLocalSharedDirectory path."
        case .missingApplicationGroup(let identifier):
            return "The App Group container is unavailable: \(identifier)"
        case .unsupportedSchema(let file, let version):
            return "Unsupported schema version \(version) in \(file)"
        case .invalidRootDocument:
            return "The registered roots document contains no valid roots"
        case .cannotCreateQueue(let error):
            return "Cannot create the Finder command queue: \(error.localizedDescription)"
        case .cannotEncodeRequest(let error):
            return "Cannot encode the Finder command: \(error.localizedDescription)"
        case .cannotWriteRequest(let error):
            return "Cannot write the Finder command: \(error.localizedDescription)"
        }
    }
}

/// Owns all I/O performed by the Finder extension.
///
/// Files are intentionally small, bounded, and replace-only. The extension
/// never touches `.svn`, invokes a process, or communicates with a repository.
final class SharedContainer {
    static let appGroupInfoKey = "SvnDockAppGroupIdentifier"
    static let localSharedDirectoryInfoKey = "SvnDockLocalSharedDirectory"
    static let defaultAppGroupIdentifier = "group.com.svndock.shared"
    static let relativeDirectory = "Library/Application Support/SvnDock"
    static let rootsFileName = "registered-roots.json"
    static let badgeFileName = "badge-snapshot.json"
    static let queueDirectoryName = "command-queue"

    /// Avoid decoding an unexpectedly large/corrupt file in Finder's process.
    private static let maximumSharedFileSize = 8 * 1_024 * 1_024

    let appGroupIdentifier: String
    let containerURL: URL?

    private let configurationError: SharedContainerError?
    private let localSharedDirectoryURL: URL?
    private let fileManager: FileManager
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(bundle: Bundle = .main, fileManager: FileManager = .default) {
        let configuredIdentifier = (bundle.object(
            forInfoDictionaryKey: Self.appGroupInfoKey
        ) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedIdentifier: String
        let resolvedConfigurationError: SharedContainerError?
        let resolvedLocalSharedDirectoryURL: URL?

        #if SVNDOCK_LOCAL_SIGNED_BUILD
        let configuredLocalPath = (bundle.object(
            forInfoDictionaryKey: Self.localSharedDirectoryInfoKey
        ) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let configuredLocalPath,
           configuredLocalPath.hasPrefix("/"),
           !configuredLocalPath.contains("$(") {
            resolvedIdentifier = configuredIdentifier ?? Self.defaultAppGroupIdentifier
            resolvedConfigurationError = nil
            resolvedLocalSharedDirectoryURL = URL(
                fileURLWithPath: configuredLocalPath,
                isDirectory: true
            ).standardizedFileURL
        } else {
            resolvedIdentifier = ""
            resolvedConfigurationError = .invalidLocalSharedDirectoryConfiguration
            resolvedLocalSharedDirectoryURL = nil
        }
        #else
        if let configuredIdentifier,
           configuredIdentifier.hasPrefix("group."),
           configuredIdentifier.count > "group.".count,
           !configuredIdentifier.contains("$(") {
            resolvedIdentifier = configuredIdentifier
            resolvedConfigurationError = nil
        } else {
            #if DEBUG
            // SwiftPM and preview builds do not process the Xcode Info.plist.
            resolvedIdentifier = Self.defaultAppGroupIdentifier
            resolvedConfigurationError = nil
            #else
            resolvedIdentifier = ""
            resolvedConfigurationError = .invalidApplicationGroupConfiguration
            #endif
        }
        resolvedLocalSharedDirectoryURL = nil
        #endif
        self.appGroupIdentifier = resolvedIdentifier
        self.configurationError = resolvedConfigurationError
        self.localSharedDirectoryURL = resolvedLocalSharedDirectoryURL
        self.fileManager = fileManager
        if resolvedConfigurationError == nil,
           resolvedLocalSharedDirectoryURL == nil {
            self.containerURL = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: resolvedIdentifier
            )
        } else {
            self.containerURL = nil
        }
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    var sharedDirectoryURL: URL? {
        localSharedDirectoryURL
            ?? containerURL?.appendingPathComponent(Self.relativeDirectory, isDirectory: true)
    }

    var registeredRootsURL: URL? {
        sharedDirectoryURL?.appendingPathComponent(Self.rootsFileName, isDirectory: false)
    }

    var badgeSnapshotURL: URL? {
        sharedDirectoryURL?.appendingPathComponent(Self.badgeFileName, isDirectory: false)
    }

    var commandQueueURL: URL? {
        sharedDirectoryURL?.appendingPathComponent(Self.queueDirectoryName, isDirectory: true)
    }

    func loadRegisteredRoots() throws -> [RegisteredRoot] {
        try validateConfiguration()
        guard let url = registeredRootsURL else {
            throw SharedContainerError.missingApplicationGroup(appGroupIdentifier)
        }
        guard let document: RegisteredRootsDocument = try readJSONIfPresent(
            RegisteredRootsDocument.self,
            from: url
        ) else {
            return []
        }
        guard document.schemaVersion == RegisteredRootsDocument.currentSchemaVersion else {
            throw SharedContainerError.unsupportedSchema(
                file: Self.rootsFileName,
                version: document.schemaVersion
            )
        }

        // Reject relative paths and remove duplicate/nested textual aliases.
        var seen = Set<String>()
        return document.roots.compactMap { root in
            guard root.enabled, let url = root.canonicalURL else { return nil }
            let path = url.path
            guard seen.insert(path).inserted else { return nil }
            return RegisteredRoot(
                id: root.id,
                path: path,
                displayName: root.displayName,
                enabled: true
            )
        }
    }

    func loadBadgeSnapshot() throws -> BadgeSnapshotDocument {
        try validateConfiguration()
        guard let url = badgeSnapshotURL else {
            throw SharedContainerError.missingApplicationGroup(appGroupIdentifier)
        }
        guard let document: BadgeSnapshotDocument = try readJSONIfPresent(
            BadgeSnapshotDocument.self,
            from: url
        ) else {
            return BadgeSnapshotDocument(
                schemaVersion: BadgeSnapshotDocument.currentSchemaVersion,
                generatedAt: nil,
                entries: [:]
            )
        }
        guard document.schemaVersion == BadgeSnapshotDocument.currentSchemaVersion else {
            throw SharedContainerError.unsupportedSchema(
                file: Self.badgeFileName,
                version: document.schemaVersion
            )
        }

        var canonicalEntries: [String: BadgeKind] = [:]
        canonicalEntries.reserveCapacity(document.entries.count)
        for (path, kind) in document.entries where path.hasPrefix("/") {
            canonicalEntries[URL(fileURLWithPath: path).standardizedFileURL.path] = kind
        }
        return BadgeSnapshotDocument(
            schemaVersion: document.schemaVersion,
            generatedAt: document.generatedAt,
            entries: canonicalEntries
        )
    }

    /// Atomically adds a request to the append-only inbox. The main app must
    /// independently validate every request before consuming it.
    @discardableResult
    func enqueue(_ request: FinderCommandRequest) throws -> URL {
        try validateConfiguration()
        guard let queueURL = commandQueueURL else {
            throw SharedContainerError.missingApplicationGroup(appGroupIdentifier)
        }
        do {
            try fileManager.createDirectory(
                at: queueURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw SharedContainerError.cannotCreateQueue(error)
        }

        let data: Data
        do {
            data = try encoder.encode(request)
        } catch {
            throw SharedContainerError.cannotEncodeRequest(error)
        }

        let destination = queueURL
            .appendingPathComponent(request.id.uuidString.lowercased(), isDirectory: false)
            .appendingPathExtension("json")
        do {
            try data.write(to: destination, options: [.atomic])
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        } catch {
            throw SharedContainerError.cannotWriteRequest(error)
        }
        return destination
    }

    private func validateConfiguration() throws {
        if let configurationError {
            throw configurationError
        }
    }

    private func readJSONIfPresent<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber,
           size.intValue > Self.maximumSharedFileSize {
            return nil
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try decoder.decode(type, from: data)
    }
}

/// Thread-safe in-memory view used by Finder callbacks.
final class SharedStateStore {
    private let container: SharedContainer
    private let lock = NSLock()
    private var roots: [RegisteredRoot] = []
    private var badgeEntries: [String: BadgeKind] = [:]

    init(container: SharedContainer) {
        self.container = container
    }

    @discardableResult
    func reload() -> [RegisteredRoot] {
        let loadedRoots = (try? container.loadRegisteredRoots()) ?? []
        let loadedBadges = (try? container.loadBadgeSnapshot().entries) ?? [:]
        lock.lock()
        roots = loadedRoots
        badgeEntries = loadedBadges
        lock.unlock()
        return loadedRoots
    }

    func registeredRoots() -> [RegisteredRoot] {
        lock.lock()
        defer { lock.unlock() }
        return roots
    }

    func badge(for url: URL) -> BadgeKind? {
        let path = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        return badgeEntries[path]
    }

    /// Uses a component boundary and picks the deepest match, so `/repo-a`
    /// never matches `/repo-ab` and nested working copies remain deterministic.
    func root(containing url: URL) -> RegisteredRoot? {
        let path = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        return roots
            .filter { Self.contains(path: path, rootPath: $0.path) }
            .max { $0.path.count < $1.path.count }
    }

    private static func contains(path: String, rootPath: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}
