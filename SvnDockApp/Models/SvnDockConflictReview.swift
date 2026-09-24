import Foundation

/// A frozen selection, not a snapshot of file contents. The service rechecks
/// SVN conflict state under the working-copy lock before applying a strategy.
struct SvnDockConflictReview: Identifiable, Sendable {
    let id = UUID()
    let workingCopy: SvnDockWorkingCopy
    let entries: [SvnDockStatusEntry]
    let excludedSelectionCount: Int

    var replaceableEntryIDs: Set<String> {
        Set(entries.filter {
            $0.nodeKind == .file && !$0.isSymbolicLink && $0.conflictKinds == [.text]
        }.map(\.id))
    }

    var allowsFileReplacement: Bool {
        !entries.isEmpty && replaceableEntryIDs.count == entries.count
    }

    var relativePaths: [String] { entries.map(\.relativePath) }
    var displayName: String { entries.count == 1 ? entries[0].fileName : "\(entries.count) 个项目" }
}

extension SvnDockConflictKind {
    var displayName: String {
        switch self {
        case .text: "内容冲突"
        case .property: "属性冲突"
        case .tree: "路径结构冲突"
        }
    }
}
