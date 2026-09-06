import Foundation

struct SvnDockFinderTarget: Hashable, Sendable {
    let entry: SvnDockStatusEntry
    let repositoryRelativePath: String?
}
