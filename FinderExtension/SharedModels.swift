import Foundation

/// JSON contract shared by the main application and the Finder extension.
///
/// Keep these types value-only. They deliberately do not import FinderSync,
/// AppKit, or an SVN implementation so they can later move into a shared
/// framework target without changing the on-disk schema.
struct RegisteredRootsDocument: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let roots: [RegisteredRoot]
}

struct RegisteredRoot: Codable, Hashable, Sendable {
    let id: UUID
    let path: String
    let displayName: String?
    let enabled: Bool

    var canonicalURL: URL? {
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}

enum RegisteredRootResolver {
    /// Uses a component boundary and picks the deepest match, so `/repo-a`
    /// never matches `/repo-ab` and nested working copies remain deterministic.
    static func deepestRoot(
        containing url: URL,
        among roots: [RegisteredRoot]
    ) -> RegisteredRoot? {
        let path = url.standardizedFileURL.path
        return roots
            .lazy.filter { contains(path: path, rootPath: $0.path) }
            .max { $0.path.count < $1.path.count }
    }

    private static func contains(path: String, rootPath: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}

struct BadgeSnapshotDocument: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    /// ISO-8601 text for diagnostics only. Badge rendering does not parse it.
    let generatedAt: String?
    /// Keys are absolute, standardized file-system paths.
    let entries: [String: BadgeKind]
    /// Exact SVN states are separate from ancestor display summaries.
    let directEntries: [String: BadgeKind]?
    let perRootUpdatedAt: [String: String]?

    init(schemaVersion: Int, generatedAt: String?, entries: [String: BadgeKind],
         directEntries: [String: BadgeKind]? = nil, perRootUpdatedAt: [String: String]? = nil) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.entries = entries
        self.directEntries = directEntries
        self.perRootUpdatedAt = perRootUpdatedAt
    }
}

enum BadgeKind: String, Codable, CaseIterable, Sendable {
    case modified
    case added
    case deleted
    case conflicted
    case unversioned
    case missing
    case replaced
    case ignored
    case clean

    var finderBadgeIdentifier: String {
        switch self {
        case .modified, .replaced:
            return FinderBadgeIdentifier.modified
        case .added:
            return FinderBadgeIdentifier.added
        case .deleted:
            return FinderBadgeIdentifier.deleted
        case .conflicted:
            return FinderBadgeIdentifier.conflicted
        case .unversioned:
            return FinderBadgeIdentifier.unversioned
        case .missing:
            return FinderBadgeIdentifier.missing
        case .ignored:
            return FinderBadgeIdentifier.ignored
        case .clean:
            return FinderBadgeIdentifier.clean
        }
    }

    var isLocalChange: Bool {
        switch self {
        case .modified, .added, .deleted, .conflicted, .missing, .replaced:
            return true
        case .unversioned, .ignored, .clean:
            return false
        }
    }
}

enum FinderBadgeIdentifier {
    static let clean = "SvnDock.Clean"
    static let modified = "SvnDock.Modified"
    static let added = "SvnDock.Added"
    static let deleted = "SvnDock.Deleted"
    static let conflicted = "SvnDock.Conflicted"
    static let unversioned = "SvnDock.Unversioned"
    static let missing = "SvnDock.Missing"
    static let ignored = "SvnDock.Ignored"
    static let stale = "SvnDock.Stale"
    static let unknown = "SvnDock.Unknown"
    static let none = ""
}

enum FinderBadgeColor: String, Sendable { case green, yellow, red, blue, gray }

struct FinderBadgeSymbolSpec: Equatable, Sendable {
    let identifier: String
    let symbol: String
    let label: String
    let color: FinderBadgeColor

    static let all: [Self] = [
        .init(identifier: FinderBadgeIdentifier.clean, symbol: "checkmark.circle.fill", label: "SVN 正常", color: .green),
        .init(identifier: FinderBadgeIdentifier.modified, symbol: "pencil.circle.fill", label: "SVN 已修改", color: .yellow),
        .init(identifier: FinderBadgeIdentifier.conflicted, symbol: "exclamationmark.octagon.fill", label: "SVN 冲突", color: .red),
        .init(identifier: FinderBadgeIdentifier.added, symbol: "plus.circle.fill", label: "SVN 已添加", color: .blue),
        .init(identifier: FinderBadgeIdentifier.deleted, symbol: "minus.circle.fill", label: "SVN 已删除", color: .red),
        .init(identifier: FinderBadgeIdentifier.missing, symbol: "xmark.circle.fill", label: "SVN 文件缺失", color: .red),
        .init(identifier: FinderBadgeIdentifier.unversioned, symbol: "questionmark.circle.fill", label: "SVN 未纳管", color: .gray),
        .init(identifier: FinderBadgeIdentifier.ignored, symbol: "eye.slash.circle.fill", label: "SVN 已忽略", color: .gray),
        .init(identifier: FinderBadgeIdentifier.stale, symbol: "clock.circle.fill", label: "SVN 状态待刷新", color: .gray),
        .init(identifier: FinderBadgeIdentifier.unknown, symbol: "questionmark.circle", label: "SVN 状态待确认", color: .gray)
    ]
}

enum FinderBadgeFreshness {
    static let maximumAge: TimeInterval = 60

    static func date(from timestamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestamp) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestamp)
    }

    static func isFresh(_ updatedAt: Date?, at now: Date) -> Bool {
        guard let updatedAt else { return false }
        let age = now.timeIntervalSince(updatedAt)
        return age >= -5 && age <= maximumAge
    }
}

struct FinderBadgeDirectoryRequest: Codable, Equatable, Sendable {
    let workingCopyID: UUID
    let workingCopyRoot: String
    let directoryPath: String
    let itemPaths: [String]?

    init(workingCopyID: UUID, workingCopyRoot: String, directoryPath: String, itemPaths: [String]? = nil) {
        self.workingCopyID = workingCopyID
        self.workingCopyRoot = workingCopyRoot
        self.directoryPath = directoryPath
        self.itemPaths = itemPaths
    }
}

struct FinderBadgeRequestDocument: Codable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let updatedAt: String
    let directories: [FinderBadgeDirectoryRequest]

    init(id: UUID, directories: [FinderBadgeDirectoryRequest]) {
        self.schemaVersion = 1
        self.id = id
        self.updatedAt = SVNDockTimestamp.now()
        self.directories = directories
    }

    static func encoded(id: UUID, directories: [FinderBadgeDirectoryRequest], maximumBytes: Int = 64 * 1_024) throws -> Data {
        var remainingItems = 2_048
        var bounded = directories.prefix(32).map { directory in
            let paths = Array((directory.itemPaths ?? []).prefix(remainingItems))
            remainingItems -= paths.count
            return FinderBadgeDirectoryRequest(workingCopyID: directory.workingCopyID,
                workingCopyRoot: directory.workingCopyRoot, directoryPath: directory.directoryPath,
                itemPaths: paths)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        while true {
            let data = try encoder.encode(Self(id: id, directories: bounded))
            if data.count <= maximumBytes { return data }
            // Keep the most recent directories and paths when long filenames
            // would exceed the reader's byte limit. No invalid partial JSON.
            if let index = bounded.lastIndex(where: { !($0.itemPaths ?? []).isEmpty }) {
                let previous = bounded[index]
                let paths = previous.itemPaths ?? []
                bounded[index] = FinderBadgeDirectoryRequest(workingCopyID: previous.workingCopyID,
                    workingCopyRoot: previous.workingCopyRoot, directoryPath: previous.directoryPath,
                    itemPaths: Array(paths.prefix(paths.count / 2)))
            } else if !bounded.isEmpty {
                bounded.removeLast()
            } else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
        }
    }
}

struct FinderBadgeUpdate: Equatable {
    let url: URL
    let identifier: String
}

/// Pure bookkeeping: only paths requested by Finder can receive badge updates.
/// No traversal or SVN access is performed here.
struct FinderBadgeTracker {
    private(set) var requestedURLs: [URL] = []
    private(set) var observedDirectories: [URL] = []
    private var lastIdentifiers: [String: String] = [:]
    private var recentDirectories: [URL] = []
    private let maximumRequestedURLs: Int
    private let maximumRequestDirectories: Int

    init(maximumRequestedURLs: Int = 2_048, maximumRequestDirectories: Int = 32) {
        self.maximumRequestedURLs = max(1, maximumRequestedURLs)
        self.maximumRequestDirectories = min(32, max(1, maximumRequestDirectories))
    }

    mutating func observe(_ url: URL, roots: [RegisteredRoot]) {
        guard Self.validRoot(for: url, roots: roots) != nil else { return }
        let url = url.standardizedFileURL
        observedDirectories.removeAll { $0.path == url.path }
        observedDirectories.append(url)
        if observedDirectories.count > 128 { observedDirectories.removeFirst() }
        touchDirectory(url)
    }

    mutating func stopObserving(_ url: URL) {
        let url = url.standardizedFileURL
        observedDirectories.removeAll { $0.path == url.path }
        let remainingObserved = Set(observedDirectories.map(\.path))
        let removed = requestedURLs.filter { requestedURL in
            let path = requestedURL.path
            let isWithinEndedDirectory = path == url.path || path.hasPrefix(url.path + "/")
            return isWithinEndedDirectory && !remainingObserved.contains(requestedURL.deletingLastPathComponent().path)
        }
        let removedPaths = Set(removed.map(\.path))
        requestedURLs.removeAll { removedPaths.contains($0.path) }
        for removedURL in removed { lastIdentifiers[removedURL.path] = nil }
        let activeDirectories = remainingObserved.union(requestedURLs.map { $0.deletingLastPathComponent().path })
        recentDirectories.removeAll { !activeDirectories.contains($0.path) }
    }

    mutating func request(_ url: URL, identifier: String, roots: [RegisteredRoot]) {
        guard let root = Self.validRoot(for: url, roots: roots) else { return }
        let url = url.standardizedFileURL
        requestedURLs.removeAll { $0.path == url.path }
        requestedURLs.append(url)
        lastIdentifiers[url.path] = identifier
        while requestedURLs.count > maximumRequestedURLs {
            lastIdentifiers[requestedURLs.removeFirst().path] = nil
        }
        touchDirectory(url.path == root.path ? url : url.deletingLastPathComponent())
    }

    mutating func badgeUpdates(using identifier: (URL) -> String) -> [FinderBadgeUpdate] {
        var updates: [FinderBadgeUpdate] = []
        for url in requestedURLs {
            let next = identifier(url)
            guard lastIdentifiers[url.path] != next else { continue }
            lastIdentifiers[url.path] = next
            updates.append(.init(url: url, identifier: next))
        }
        return updates
    }

    mutating func pruneUnregistered(roots: [RegisteredRoot]) {
        requestedURLs.removeAll { Self.validRoot(for: $0, roots: roots) == nil }
        observedDirectories.removeAll { Self.validRoot(for: $0, roots: roots) == nil }
        recentDirectories.removeAll { Self.validRoot(for: $0, roots: roots) == nil }
        let paths = Set(requestedURLs.map(\.path))
        lastIdentifiers = lastIdentifiers.filter { paths.contains($0.key) }
    }

    func directoryRequests(roots: [RegisteredRoot]) -> [FinderBadgeDirectoryRequest] {
        var active = Set(observedDirectories.map(\.path))
        for url in requestedURLs {
            guard let root = Self.validRoot(for: url, roots: roots) else { continue }
            active.insert(url.path == root.path ? url.path : url.deletingLastPathComponent().path)
        }
        return recentDirectories.reversed().lazy.compactMap { url -> FinderBadgeDirectoryRequest? in
            guard active.contains(url.path), let root = Self.validRoot(for: url, roots: roots) else { return nil }
            let visibleItems = requestedURLs.reversed().filter { $0.deletingLastPathComponent().path == url.path }.map(\.path)
            return .init(workingCopyID: root.id, workingCopyRoot: root.path, directoryPath: url.path, itemPaths: visibleItems)
        }.prefix(maximumRequestDirectories).map { $0 }
    }

    private mutating func touchDirectory(_ url: URL) {
        recentDirectories.removeAll { $0.path == url.path }
        recentDirectories.append(url)
        if recentDirectories.count > 2_176 { recentDirectories.removeFirst() }
    }

    private static func validRoot(for url: URL, roots: [RegisteredRoot]) -> RegisteredRoot? {
        guard url.isFileURL, !url.standardizedFileURL.pathComponents.contains(".svn") else { return nil }
        return RegisteredRootResolver.deepestRoot(containing: url, among: roots)
    }
}

enum FinderCommandKind: String, Codable, Sendable {
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

struct FinderCommandRequest: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let kind: FinderCommandKind
    let paths: [String]
    let workingCopyRoot: String
    /// ISO-8601 with fractional seconds, generated in UTC.
    let createdAt: String
    let source: String

    init(
        id: UUID = UUID(),
        kind: FinderCommandKind,
        paths: [String],
        workingCopyRoot: String,
        createdAt: String = SVNDockTimestamp.now()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.kind = kind
        self.paths = paths
        self.workingCopyRoot = workingCopyRoot
        self.createdAt = createdAt
        self.source = "finder-extension"
    }
}

private enum SVNDockTimestamp {
    static func now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }
}
