import Foundation

/// Direct SVN states and folder summaries deliberately have different consumers:
/// Finder draws summaries, but menu eligibility only uses direct states.
public struct FinderBadgeEntries: Sendable, Equatable {
    public let entries: [String: BadgeKind]
    public let directEntries: [String: BadgeKind]
}

public enum FinderBadgeBuilder {
    /// Visible directories can still contain many thousands of children. Keep
    /// optional green badges bounded; an omitted node remains unknown.
    public static let maximumCleanEntries = 4_096

    public static func build(
        from statuses: [StatusEntry],
        in workingCopy: WorkingCopy,
        excludingRoots: [String] = [],
        preferredPaths: [String] = []
    ) -> FinderBadgeEntries {
        let root = workingCopy.localPath.standardizedFileURL.path
        let excluded = excludingRoots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        var direct: [String: BadgeKind] = [:]
        var cleanCount = 0
        var cleanPathBytes = 0
        let preferred = Set(preferredPaths)
        // Finder's actually requested icons win over arbitrary dictionary
        // order when a directory exceeds the optional green-badge budget.
        let ordered = statuses.filter { preferred.contains($0.fileURL(relativeTo: workingCopy).path) }
            + statuses.filter { !preferred.contains($0.fileURL(relativeTo: workingCopy).path) }
        for entry in ordered {
            let path = entry.fileURL(relativeTo: workingCopy).standardizedFileURL.path
            guard contains(path, root: root), !excluded.contains(where: { contains(path, root: $0) }),
                  entry.isFileExternal != true, entry.status != .external else { continue }
            let badge: BadgeKind
            if entry.hasLocalChanges || entry.status == .ignored {
                badge = BadgeKind(statusEntry: entry)
            } else if entry.status == .normal,
                      entry.propertyStatus == .normal || entry.propertyStatus == .none {
                badge = .clean
            } else {
                continue
            }
            if badge == .clean, direct[path] == nil {
                guard cleanCount < maximumCleanEntries,
                      cleanPathBytes + path.utf8.count <= 512 * 1_024 else { continue }
                cleanCount += 1
                cleanPathBytes += path.utf8.count
            }
            direct[path] = badge
        }

        var display = direct
        for (path, badge) in direct where badge != .ignored && badge != .clean {
            var parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            while contains(parent, root: root) {
                display[parent] = higherPriority(display[parent], badge)
                if parent == root { break }
                parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
            }
        }
        return FinderBadgeEntries(entries: display, directEntries: direct)
    }

    private static func contains(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func higherPriority(_ lhs: BadgeKind?, _ rhs: BadgeKind) -> BadgeKind {
        guard let lhs else { return rhs }
        return priority(rhs) < priority(lhs) ? rhs : lhs
    }

    private static func priority(_ badge: BadgeKind) -> Int {
        switch badge {
        case .conflicted: 0
        case .missing: 1
        case .deleted: 2
        case .replaced: 3
        case .modified: 4
        case .added: 5
        case .unversioned: 6
        case .ignored: 7
        case .clean: 8
        }
    }
}
