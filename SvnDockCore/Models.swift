import Foundation

/// A registered Subversion working copy.
///
/// `id` is intentionally independent from the path so a working copy can be moved
/// without losing UI state or queued-operation identity.
public struct WorkingCopy: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var localPath: URL
    public var repositoryURL: URL?
    public var repositoryRootURL: URL?
    public var repositoryUUID: String?
    public var revision: Int?
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        localPath: URL,
        repositoryURL: URL? = nil,
        repositoryRootURL: URL? = nil,
        repositoryUUID: String? = nil,
        revision: Int? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.localPath = localPath.standardizedFileURL
        self.name = name ?? Self.defaultName(for: localPath)
        self.repositoryURL = repositoryURL
        self.repositoryRootURL = repositoryRootURL
        self.repositoryUUID = repositoryUUID
        self.revision = revision
        self.isEnabled = isEnabled
    }

    public var canonicalPath: String {
        localPath.standardizedFileURL.path
    }

    private static func defaultName(for url: URL) -> String {
        let name = url.standardizedFileURL.lastPathComponent
        return name.isEmpty ? url.path : name
    }
}

public enum SVNNodeKind: String, Codable, Hashable, Sendable {
    case file
    case directory
    case unknown

    public init(svnValue: String?) {
        switch svnValue?.lowercased() {
        case "file": self = .file
        case "dir", "directory": self = .directory
        default: self = .unknown
        }
    }
}

/// A status value returned by `svn status --xml`.
///
/// The associated value on `unknown` keeps SvnDock forward-compatible with a
/// newer SVN client instead of silently treating a new status as clean.
public enum SVNStatus: Codable, Hashable, Sendable {
    case added
    case conflicted
    case deleted
    case external
    case ignored
    case incomplete
    case merged
    case missing
    case modified
    case none
    case normal
    case obstructed
    case replaced
    case unversioned
    case unknown(String)

    public init(svnValue: String) {
        switch svnValue.lowercased() {
        case "added": self = .added
        case "conflicted": self = .conflicted
        case "deleted": self = .deleted
        case "external": self = .external
        case "ignored": self = .ignored
        case "incomplete": self = .incomplete
        case "merged": self = .merged
        case "missing": self = .missing
        case "modified": self = .modified
        case "none": self = .none
        case "normal": self = .normal
        case "obstructed": self = .obstructed
        case "replaced": self = .replaced
        case "unversioned": self = .unversioned
        default: self = .unknown(svnValue)
        }
    }

    public var svnValue: String {
        switch self {
        case .added: return "added"
        case .conflicted: return "conflicted"
        case .deleted: return "deleted"
        case .external: return "external"
        case .ignored: return "ignored"
        case .incomplete: return "incomplete"
        case .merged: return "merged"
        case .missing: return "missing"
        case .modified: return "modified"
        case .none: return "none"
        case .normal: return "normal"
        case .obstructed: return "obstructed"
        case .replaced: return "replaced"
        case .unversioned: return "unversioned"
        case let .unknown(value): return value
        }
    }

    public var isLocalChange: Bool {
        switch self {
        case .added, .conflicted, .deleted, .incomplete, .merged, .missing,
             .modified, .obstructed, .replaced, .unversioned:
            return true
        case .external, .ignored, .none, .normal, .unknown:
            return false
        }
    }
}

public struct SVNCommitInfo: Codable, Hashable, Sendable {
    public let revision: Int?
    public let author: String?
    public let date: Date?

    public init(revision: Int?, author: String?, date: Date?) {
        self.revision = revision
        self.author = author
        self.date = date
    }
}

/// One revision returned by `svn log --xml`.
///
/// A revision number is mandatory in Subversion's XML schema. Author and date
/// remain optional because repositories may contain revisions created without
/// either value, and an empty commit message is valid SVN history.
public struct SVNLogEntry: Identifiable, Codable, Hashable, Sendable {
    public let revision: Int
    public let author: String?
    public let date: Date?
    public let message: String
    public let changedPaths: [SVNChangedPath]

    public init(
        revision: Int,
        author: String?,
        date: Date?,
        message: String,
        changedPaths: [SVNChangedPath] = []
    ) {
        self.revision = revision
        self.author = author
        self.date = date
        self.message = message
        self.changedPaths = changedPaths
    }

    public var id: Int { revision }
}

public struct SVNProperty: Codable, Hashable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct SVNPropertyListEntry: Identifiable, Codable, Hashable, Sendable {
    public let path: String
    public let properties: [SVNProperty]

    public init(path: String, properties: [SVNProperty]) {
        self.path = path
        self.properties = properties
    }

    public var id: String { path }

    public func value(forProperty name: String) -> String? {
        properties.first { $0.name == name }?.value
    }
}

public struct StatusEntry: Identifiable, Codable, Hashable, Sendable {
    /// The path exactly as reported by SVN, normally relative to the working copy.
    public let path: String
    public let kind: SVNNodeKind
    public let status: SVNStatus
    public let propertyStatus: SVNStatus
    public let repositoryStatus: SVNStatus?
    public let repositoryPropertyStatus: SVNStatus?
    public let revision: Int?
    public let isCopied: Bool
    public let isSwitched: Bool
    /// Optional so persisted status snapshots from older versions still decode.
    public let isFileExternal: Bool?
    public let isTreeConflicted: Bool
    public let changelist: String?
    public let lastCommit: SVNCommitInfo?

    public init(
        path: String,
        kind: SVNNodeKind = .unknown,
        status: SVNStatus,
        propertyStatus: SVNStatus = .none,
        repositoryStatus: SVNStatus? = nil,
        repositoryPropertyStatus: SVNStatus? = nil,
        revision: Int? = nil,
        isCopied: Bool = false,
        isSwitched: Bool = false,
        isFileExternal: Bool? = nil,
        isTreeConflicted: Bool = false,
        changelist: String? = nil,
        lastCommit: SVNCommitInfo? = nil
    ) {
        self.path = path
        self.kind = kind
        self.status = status
        self.propertyStatus = propertyStatus
        self.repositoryStatus = repositoryStatus
        self.repositoryPropertyStatus = repositoryPropertyStatus
        self.revision = revision
        self.isCopied = isCopied
        self.isSwitched = isSwitched
        self.isFileExternal = isFileExternal
        self.isTreeConflicted = isTreeConflicted
        self.changelist = changelist
        self.lastCommit = lastCommit
    }

    public var id: String { path }
    public var isDirectory: Bool { kind == .directory }
    public var hasLocalChanges: Bool {
        status.isLocalChange || propertyStatus.isLocalChange || isTreeConflicted
    }

    public func fileURL(relativeTo workingCopy: WorkingCopy) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return workingCopy.localPath.appendingPathComponent(path).standardizedFileURL
    }
}

public struct SVNInfo: Codable, Hashable, Sendable {
    public let path: String
    public let kind: SVNNodeKind
    public let revision: Int?
    public let url: URL?
    public let repositoryRootURL: URL?
    public let repositoryUUID: String?
    public let workingCopyRootURL: URL?
    public let schedule: String?
    public let depth: String?
    public let lastCommit: SVNCommitInfo?

    public init(
        path: String,
        kind: SVNNodeKind,
        revision: Int?,
        url: URL?,
        repositoryRootURL: URL?,
        repositoryUUID: String?,
        workingCopyRootURL: URL?,
        schedule: String?,
        depth: String?,
        lastCommit: SVNCommitInfo?
    ) {
        self.path = path
        self.kind = kind
        self.revision = revision
        self.url = url
        self.repositoryRootURL = repositoryRootURL
        self.repositoryUUID = repositoryUUID
        self.workingCopyRootURL = workingCopyRootURL
        self.schedule = schedule
        self.depth = depth
        self.lastCommit = lastCommit
    }
}

public struct SVNStatusOptions: Codable, Hashable, Sendable {
    public var showRemoteUpdates: Bool
    public var includeIgnored: Bool
    /// Explicitly include normal versioned nodes for bounded Finder listings.
    public var includeUnchanged: Bool
    public var ignoreExternals: Bool
    /// Limits how deeply Subversion inspects directory targets. `nil` keeps
    /// the client's default recursive behavior.
    public var depth: SVNDepth?
    /// Optional working-copy-relative paths to inspect. An empty collection
    /// keeps the original whole-working-copy behavior.
    public var paths: [String]

    public init(
        showRemoteUpdates: Bool = false,
        includeIgnored: Bool = false,
        includeUnchanged: Bool = false,
        ignoreExternals: Bool = false,
        depth: SVNDepth? = nil,
        paths: [String] = []
    ) {
        self.showRemoteUpdates = showRemoteUpdates
        self.includeIgnored = includeIgnored
        self.includeUnchanged = includeUnchanged
        self.ignoreExternals = ignoreExternals
        self.depth = depth
        self.paths = paths
    }

    private enum CodingKeys: String, CodingKey {
        case showRemoteUpdates
        case includeIgnored
        case includeUnchanged
        case ignoreExternals
        case depth
        case paths
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showRemoteUpdates = try container.decode(Bool.self, forKey: .showRemoteUpdates)
        includeIgnored = try container.decode(Bool.self, forKey: .includeIgnored)
        includeUnchanged = try container.decodeIfPresent(Bool.self, forKey: .includeUnchanged) ?? false
        ignoreExternals = try container.decodeIfPresent(Bool.self, forKey: .ignoreExternals) ?? false
        depth = try container.decodeIfPresent(SVNDepth.self, forKey: .depth)
        paths = try container.decodeIfPresent([String].self, forKey: .paths) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(showRemoteUpdates, forKey: .showRemoteUpdates)
        try container.encode(includeIgnored, forKey: .includeIgnored)
        if includeUnchanged { try container.encode(true, forKey: .includeUnchanged) }
        if ignoreExternals { try container.encode(true, forKey: .ignoreExternals) }
        try container.encodeIfPresent(depth, forKey: .depth)
        if !paths.isEmpty {
            try container.encode(paths, forKey: .paths)
        }
    }
}

public enum SVNRevision: Codable, Hashable, Sendable {
    case head
    case working
    case base
    case committed
    case previous
    case number(Int)

    public var commandLineValue: String {
        switch self {
        case .head: return "HEAD"
        case .working: return "WORKING"
        case .base: return "BASE"
        case .committed: return "COMMITTED"
        case .previous: return "PREV"
        case let .number(value): return String(value)
        }
    }
}

public enum SVNDepth: String, Codable, Hashable, Sendable {
    case empty
    case files
    case immediates
    case infinity
}

public enum SVNConflictChoice: String, Codable, Hashable, Sendable {
    case base
    case working
    case mineConflict = "mine-conflict"
    case theirsConflict = "theirs-conflict"
    case mineFull = "mine-full"
    case theirsFull = "theirs-full"
}

public enum SVNOperationKind: Codable, Hashable, Sendable {
    case status(SVNStatusOptions)
    case info
    case infoTargets(paths: [String])
    case update(revision: SVNRevision?)
    case commit(paths: [String], message: String, keepLocks: Bool, depth: SVNDepth? = nil)
    case add(paths: [String], parents: Bool, force: Bool, depth: SVNDepth?)
    case delete(paths: [String])
    case revert(paths: [String], depth: SVNDepth)
    case cleanup
    case diff(paths: [String], depth: SVNDepth? = nil)
    case localDifference(relativePath: String, ignoringWhitespace: Bool)
    case log(paths: [String], limit: Int, beforeRevision: Int? = nil)
    case revisionLog(repositoryRoot: URL, revision: Int)
    case revisionSummary(repositoryRoot: URL, revision: Int)
    case revisionCopyDeletionSummary(repositoryRoot: URL, revision: Int, change: SVNChangedPath)
    case revisionDiff(repositoryRoot: URL, revision: Int, change: SVNChangedPath)
    case resolve(paths: [String], accept: SVNConflictChoice)
    case properties(paths: [String])
    case setIgnore(path: String, patterns: [String])

    public var mutatesWorkingCopy: Bool {
        switch self {
        case .update, .commit, .add, .delete, .revert, .cleanup, .resolve, .setIgnore:
            return true
        case .status, .info, .infoTargets, .diff, .localDifference, .log, .revisionLog, .revisionSummary, .revisionCopyDeletionSummary, .revisionDiff, .properties:
            return false
        }
    }
}

/// A stable operation model suitable for queues, progress UI and diagnostics.
public struct SVNOperation: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let workingCopyID: UUID
    public let kind: SVNOperationKind
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        workingCopyID: UUID,
        kind: SVNOperationKind,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.workingCopyID = workingCopyID
        self.kind = kind
        self.createdAt = createdAt
    }
}
