import Foundation

/// Presentation-only parents never become selectable SVN targets.
struct SvnDockStatusTree {
    struct Node: Identifiable {
        let path: String
        let name: String
        let entry: SvnDockStatusEntry?
        let children: [Node]
        let itemCount: Int
        var id: String { path }
        var isDirectory: Bool { entry?.nodeKind == .directory || !children.isEmpty }
    }

    let roots: [Node]

    init(entries: [SvnDockStatusEntry], compact: Bool = true) {
        var indexed: [String: SvnDockStatusEntry] = [:]
        var children: [String: Set<String>] = [:]
        for entry in entries {
            let path = entry.relativePath
            if indexed[path] == nil { indexed[path] = entry }
            guard path != "." else { continue }
            var child = path
            while child != "." {
                let component = (child as NSString).deletingLastPathComponent
                let parent = component.isEmpty ? "." : component
                children[parent, default: []].insert(child)
                child = parent
            }
        }
        func node(_ path: String) -> Node {
            let nested = children[path, default: []].map(node).sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            let entry = indexed[path]
            let name = path == "." ? "工作副本" : (path as NSString).lastPathComponent
            let count = nested.reduce(entry == nil ? 0 : 1) { $0 + $1.itemCount }
            // Keep real directory rows intact: they can carry properties,
            // conflicts, addition schedules, or user-selected operation scope.
            if compact, entry == nil, nested.count == 1, let only = nested.first,
               only.entry == nil, only.isDirectory {
                return Node(path: only.path, name: name + "/" + only.name,
                            entry: nil, children: only.children, itemCount: count)
            }
            return Node(path: path, name: name, entry: entry, children: nested, itemCount: count)
        }
        let root = node(".")
        roots = indexed["."] == nil ? root.children : [root]
    }

    var directoryPaths: Set<String> {
        func collect(_ nodes: [Node]) -> Set<String> {
            nodes.reduce(into: Set<String>()) { result, node in
                if node.isDirectory { result.insert(node.path) }
                result.formUnion(collect(node.children))
            }
        }
        return collect(roots)
    }
}
