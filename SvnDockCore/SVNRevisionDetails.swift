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

    /// A descendant removed in the same commit as its ancestor's copy has no
    /// destination node on either side of the revision. Its old content comes
    /// from the copied ancestor's source revision.
    public var deletesCopySource: Bool {
        action == .deleted && copyFromPath != nil && copyFromRevision != nil
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
    /// summary supplies those files; the log supplies ancestry, replacements,
    /// and copied descendants deleted before they ever existed at the destination.
    public static func combining(repositoryRootURL root: URL, entry: SVNLogEntry,
                                 summary: [SVNDiffSummaryEntry]) throws -> SVNRevisionDetails {
        let explicit = Dictionary(entry.changedPaths.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        var items = try summary.map { item in
            (path: try SVNRepositoryPath.path(for: item.url, in: root), action: item.action, kind: item.kind)
        }
        let summaryPaths = Set(items.map(\.path))
        for logged in explicit.values where !summaryPaths.contains(logged.path) {
            _ = try SVNRepositoryPath.validate(logged.path)
            items.append((path: logged.path, action: logged.action, kind: logged.kind))
        }
        var combined: [String: SVNChangedPath] = [:]
        for item in items {
            let path = item.path
            let existing = combined[path]
            let action: SVNChangeAction
            if let logged = explicit[path] {
                action = logged.action
            } else if let existing, existing.action != item.action {
                action = .replaced
            } else {
                action = item.action
            }
            // Summary-backed deletions existed at the destination in N-1,
            // including implicit descendants of a copied replacement. Their
            // old content must never come from the replacement's copy source.
            let canInheritCopySource = action != .deleted || !summaryPaths.contains(path)
            var source = canInheritCopySource ? explicit[path] : nil
            if source?.copyFromPath == nil,
               source?.action == .modified || (action == .deleted && !summaryPaths.contains(path)) {
                source = nil
            }
            var ancestor = path
            while canInheritCopySource, source == nil, ancestor != "/" {
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
        }.sorted(by: Self.changeOrder))
    }

    /// Expanding an ancestor already supplies every descendant from the same
    /// copied tree. Keep separate roots when their copy source or revision differs.
    public var deletedCopyDirectoriesToExpand: [SVNChangedPath] {
        let directories = Dictionary(changes.filter { $0.kind == .directory }.map { ($0.path, $0) },
                                     uniquingKeysWith: { _, last in last })
        var roots: [SVNChangedPath] = []
        for change in changes.filter({ $0.kind == .directory && $0.deletesCopySource })
            .sorted(by: { $0.path.count < $1.path.count }) {
            var ancestor = change.path
            var covered = false
            while ancestor != "/" {
                ancestor = (ancestor as NSString).deletingLastPathComponent
                if ancestor.isEmpty { ancestor = "/" }
                if let parent = directories[ancestor] {
                    if parent.deletesCopySource, parent.copyFromRevision == change.copyFromRevision,
                       let source = parent.copyFromPath,
                       let suffix = Self.descendantSuffix(change.path, under: parent.path) {
                        covered = change.copyFromPath == Self.appending(suffix, to: source)
                    }
                    // A different intervening tree prevents a more distant
                    // ancestor from supplying this directory's descendants.
                    break
                }
            }
            if !covered { roots.append(change) }
        }
        return roots
    }

    /// SVN's verbose log records a removed copied directory without its files,
    /// and the N-1:N summary has no destination tree to expand. A source-to-r0
    /// summary supplies that tree without relying on current repository contents.
    public func addingDeletedCopyDescendants(
        _ summary: [SVNDiffSummaryEntry], of directory: SVNChangedPath
    ) throws -> SVNRevisionDetails {
        guard directory.kind == .directory, directory.deletesCopySource,
              let source = directory.copyFromPath, let sourceRevision = directory.copyFromRevision,
              sourceRevision >= 0, sourceRevision < entry.revision else {
            throw SVNCommandBuilderError.invalidArgument("A valid copied directory deletion is required")
        }
        _ = try SVNRepositoryPath.validate(directory.path)
        _ = try SVNRepositoryPath.validate(source)
        let separateTrees = changes.filter { change in
            guard change.kind == .directory, change.path != directory.path,
                  let suffix = Self.descendantSuffix(change.path, under: directory.path) else { return false }
            return change.action != .deleted || change.copyFromRevision != sourceRevision
                || change.copyFromPath != Self.appending(suffix, to: source)
        }
        var combined = Dictionary(changes.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        for item in summary {
            let sourcePath = try SVNRepositoryPath.path(for: item.url, in: repositoryRootURL)
            guard item.action == .deleted,
                  let suffix = Self.descendantSuffix(sourcePath, under: source) else {
                throw SVNCommandBuilderError.invalidArgument("Deletion summary path outside copied source")
            }
            let path = Self.appending(suffix, to: directory.path)
            if separateTrees.contains(where: { Self.descendantSuffix(path, under: $0.path) != nil }) { continue }
            // Explicit logs remain authoritative for nested copy/replacement
            // ancestry, while this inventory supplies only omitted descendants.
            if combined[path] == nil {
                combined[path] = SVNChangedPath(path: path, action: .deleted, kind: item.kind,
                    copyFromPath: sourcePath, copyFromRevision: sourceRevision)
            }
        }
        return SVNRevisionDetails(repositoryRootURL: repositoryRootURL, entry: entry,
            changes: combined.values.sorted(by: Self.changeOrder))
    }

    private static func descendantSuffix(_ path: String, under root: String) -> String? {
        if path == root { return "" }
        if root == "/" { return path }
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count))
    }

    private static func appending(_ suffix: String, to path: String) -> String {
        path == "/" && !suffix.isEmpty ? suffix : path + suffix
    }

    private static func changeOrder(_ lhs: SVNChangedPath, _ rhs: SVNChangedPath) -> Bool {
        if (lhs.kind == .directory) != (rhs.kind == .directory) { return lhs.kind != .directory }
        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
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
