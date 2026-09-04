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

struct BadgeSnapshotDocument: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    /// ISO-8601 text for diagnostics only. Badge rendering does not parse it.
    let generatedAt: String?
    /// Keys are absolute, standardized file-system paths.
    let entries: [String: BadgeKind]
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
        case .ignored, .clean:
            return FinderBadgeIdentifier.none
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
    static let modified = "SvnDock.Modified"
    static let added = "SvnDock.Added"
    static let deleted = "SvnDock.Deleted"
    static let conflicted = "SvnDock.Conflicted"
    static let unversioned = "SvnDock.Unversioned"
    static let missing = "SvnDock.Missing"
    static let none = ""
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
