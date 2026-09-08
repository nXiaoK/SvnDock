import Foundation

/// Shared by the context menu and multi-selection inspector so action counts
/// describe the same subset that the store accepts.
struct StatusActionSelection {
    let entries: [SvnDockStatusEntry]

    static func context(
        for entry: SvnDockStatusEntry,
        selectedEntries: [SvnDockStatusEntry]
    ) -> Self {
        Self(entries: selectedEntries.contains(where: { $0.id == entry.id })
             ? selectedEntries : [entry])
    }

    var entryIDs: Set<SvnDockStatusEntry.ID> { Set(entries.map(\.id)) }
    var addableEntries: [SvnDockStatusEntry] {
        entries.filter { $0.status == .unversioned || ($0.status == .added && $0.nodeKind == .directory) }
    }
    var addActionTitle: String {
        if entries.count == 1, addableEntries.first?.status == .added {
            return "添加目录内容到 SVN"
        }
        return "添加 \(countLabel(addableEntries.count)) 到 SVN"
    }
    var revertibleEntries: [SvnDockStatusEntry] { entries.filter { $0.status.isChange } }
    var ignorableEntries: [SvnDockStatusEntry] { entries.filter { $0.status == .unversioned } }
    var extensionIgnorableEntries: [SvnDockStatusEntry] {
        ignorableEntries.filter { $0.nodeKind == .file && !($0.relativePath as NSString).pathExtension.isEmpty }
    }
    var directoryCount: Int { entries.filter { $0.nodeKind == .directory }.count }

    func countLabel(_ count: Int) -> String {
        count == entries.count ? "\(count) 项" : "\(count) / \(entries.count) 项"
    }
}
