import Foundation
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum StatusTreeRegressionChecks {
    static func run() throws {
        let id = UUID()
        func entry(_ path: String, directory: Bool = false) -> SvnDockStatusEntry {
            .init(workingCopyID: id, relativePath: path, nodeKind: directory ? .directory : .file, status: .added)
        }
        let first = entry("project/src/pages/a.vue")
        let second = entry("project/src/pages/b.vue")
        let folder = entry("project", directory: true)
        let tree = SvnDockStatusTree(entries: [first, entry("README.md"), second, folder, first])
        guard tree.roots.count == 2, let project = tree.roots.first,
              project.entry?.id == folder.id, project.children.count == 1,
              let group = project.children.first else { throw Failure("Directories must group all descendants before root files") }
        try check(group.name == "src/pages" && group.entry == nil, "Only presentation-only directory chains may be compacted")
        try check(group.itemCount == 2 && group.children.map(\.entry?.id) == [first.id, second.id],
                  "Repeated snapshot and lazy rows must not duplicate targets or inflate counts")
        try check(project.entry?.id == folder.id && project.itemCount == 3, "Real added directory remains a distinct explicit target")
        let expanded = SvnDockStatusTree(entries: [first], compact: false)
        try check(expanded.roots.first?.name == "project", "Uncompacted tree retains each directory segment")
        try check(expanded.roots.first?.entry == nil, "Synthetic ancestor must never become a selectable SVN entry")
        let partial = SvnDockStatusTree(entries: [first])
        try check(partial.roots.first?.itemCount == 1, "Filtered/paged trees count only supplied items")
        let sibling = SvnDockStatusTree(entries: [entry("app/file"), entry("app-other/file")])
        try check(sibling.roots.count == 2, "Directory prefix collisions must not merge unrelated scopes")
        let root = SvnDockStatusTree(entries: [entry(".", directory: true), first])
        try check(root.roots.count == 1 && root.roots[0].entry?.relativePath == ".", "Root properties remain selectable without duplicating descendants")
        print("Status tree checks passed: hierarchy, compression, explicit selection, deduplication and filtered counts")
    }
    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }
    private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
