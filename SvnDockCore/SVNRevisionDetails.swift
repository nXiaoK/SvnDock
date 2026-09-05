import Foundation

public enum SVNChangeAction: String, Codable, Hashable, Sendable {
    case added = "A", modified = "M", deleted = "D", replaced = "R", unknown = "?"
}

/// Repository-relative paths, independent of whether a node exists locally or
/// at HEAD. Copies retain the actual source revision, not an assumed N-1.
public struct SVNChangedPath: Identifiable, Codable, Hashable, Sendable {
    public let path: String
    public let action: SVNChangeAction
    public let kind: SVNNodeKind
    public let copyFromPath: String?
    public let copyFromRevision: Int?
    public let isMove: Bool

    public init(path: String, action: SVNChangeAction, kind: SVNNodeKind,
                copyFromPath: String? = nil, copyFromRevision: Int? = nil, isMove: Bool = false) {
        self.path = path
        self.action = action
        self.kind = kind
        self.copyFromPath = copyFromPath
        self.copyFromRevision = copyFromRevision
        self.isMove = isMove
    }

    public var id: String { path }
    public var comparesCopySource: Bool {
        (action == .added || action == .modified) && copyFromPath != nil && copyFromRevision != nil
    }
}

public struct SVNDiffSummaryEntry: Hashable, Sendable {
    public let url: String
    public let action: SVNChangeAction
    public let kind: SVNNodeKind
}

public struct SVNRevisionDetails: Hashable, Sendable {
    public let repositoryRootURL: URL
    public let entry: SVNLogEntry
    public let changes: [SVNChangedPath]

    public init(repositoryRootURL: URL, entry: SVNLogEntry, changes: [SVNChangedPath]) {
        self.repositoryRootURL = repositoryRootURL
        self.entry = entry
        self.changes = changes
    }

    /// Verbose logs omit descendants of copied/deleted directories. A revision
    /// summary supplies those files; the log supplies ancestry and replacements.
    public static func combining(repositoryRootURL root: URL, entry: SVNLogEntry,
                                 summary: [SVNDiffSummaryEntry]) throws -> SVNRevisionDetails {
        let explicit = Dictionary(entry.changedPaths.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        var combined: [String: SVNChangedPath] = [:]
        for item in summary {
            let path = try SVNRepositoryPath.path(for: item.url, in: root)
            let existing = combined[path]
            let action: SVNChangeAction
            if let logged = explicit[path] {
                action = logged.action
            } else if let existing, existing.action != item.action {
                action = .replaced
            } else {
                action = item.action
            }
            var source = explicit[path]
            if source?.copyFromPath == nil, source?.action == .modified { source = nil }
            var ancestor = path
            while source == nil, ancestor != "/" {
                ancestor = (ancestor as NSString).deletingLastPathComponent
                if ancestor.isEmpty { ancestor = "/" }
                if let candidate = explicit[ancestor], candidate.copyFromPath != nil {
                    source = candidate
                }
            }
            let copyPath: String?
            if let source, let origin = source.copyFromPath {
                let suffix = String(path.dropFirst(source.path.count))
                copyPath = origin == "/" && suffix.hasPrefix("/") ? suffix : origin + suffix
            } else { copyPath = nil }
            combined[path] = SVNChangedPath(
                path: path, action: action, kind: item.kind,
                copyFromPath: copyPath, copyFromRevision: source?.copyFromRevision
            )
        }
        let deleted = Set(combined.values.filter { $0.action == .deleted }.map(\.path))
        let changes = combined.values.map { change in
            var source = change.copyFromPath
            var moved = false
            while let path = source, !path.isEmpty {
                if deleted.contains(path) { moved = true; break }
                if path == "/" { break }
                source = (path as NSString).deletingLastPathComponent
            }
            return SVNChangedPath(
                path: change.path, action: change.action, kind: change.kind,
                copyFromPath: change.copyFromPath, copyFromRevision: change.copyFromRevision,
                isMove: moved && change.comparesCopySource
            )
        }
        // A move is one navigable item with both paths; retain unmatched deletes.
        let moveSources = Set(changes.filter(\.isMove).compactMap(\.copyFromPath))
        return SVNRevisionDetails(repositoryRootURL: root, entry: entry, changes: changes.filter {
            !($0.action == .deleted && moveSources.contains($0.path))
        }.sorted {
            if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind != .directory }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        })
    }
}

public enum SVNRepositoryPath {
    public static func validate(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0"),
              path == "/" || path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SVNCommandBuilderError.invalidArgument("Invalid repository path: \(path)")
        }
        return path == "/" ? "." : String(path.dropFirst())
    }

    public static func path(for rawURL: String, in root: URL) throws -> String {
        guard let url = URL(string: rawURL), url.scheme == root.scheme,
              url.host == root.host, url.port == root.port else {
            throw SVNCommandBuilderError.invalidArgument("Invalid repository summary URL")
        }
        let rootPath = root.path.removingTrailingSlash
        let path = url.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else {
            throw SVNCommandBuilderError.invalidArgument("Summary path outside repository")
        }
        let relative = String(path.dropFirst(rootPath.count))
        _ = try validate(relative.isEmpty ? "/" : relative)
        return relative.isEmpty ? "/" : relative
    }
}

private extension String {
    var removingTrailingSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}
