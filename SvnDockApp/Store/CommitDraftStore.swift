import Foundation

/// Application-private editing state. These paths describe inclusion choices;
/// they do not stage or freeze the contents of working-copy files.
struct SvnDockCommitDraft: Codable, Equatable, Sendable {
    var message: String
    var includedRelativePaths: Set<String>
    var previewRelativePath: String?

    func includedEntryIDs(in entries: [SvnDockStatusEntry]) -> Set<SvnDockStatusEntry.ID> {
        Set(entries.lazy.filter { includedRelativePaths.contains($0.relativePath) }.map(\.id))
    }

    static func initialIncludedEntryIDs(
        entries: [SvnDockStatusEntry],
        selectedEntryIDs: Set<SvnDockStatusEntry.ID>,
        savedDraft: Self?
    ) -> Set<SvnDockStatusEntry.ID> {
        if let savedDraft {
            // An explicitly empty saved selection is meaningful. Do not select
            // newly changed files just because an older draft has no matches.
            return savedDraft.includedEntryIDs(in: entries)
        }
        let availableIDs = Set(entries.map(\.id))
        return selectedEntryIDs.isEmpty ? availableIDs : selectedEntryIDs.intersection(availableIDs)
    }
}

@MainActor
final class SvnDockCommitDraftStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func draft(for workingCopy: SvnDockWorkingCopy) throws -> SvnDockCommitDraft? {
        guard let data = defaults.data(forKey: storageKey(for: workingCopy)) else { return nil }
        return try JSONDecoder().decode(SvnDockCommitDraft.self, from: data)
    }

    func save(_ draft: SvnDockCommitDraft, for workingCopy: SvnDockWorkingCopy) throws {
        let data = try JSONEncoder().encode(draft)
        defaults.set(data, forKey: storageKey(for: workingCopy))
    }

    /// Call only after a confirmed commit success, or an explicit discard.
    /// Failure and an uncertain server result must leave the draft intact.
    func remove(for workingCopy: SvnDockWorkingCopy) {
        defaults.removeObject(forKey: storageKey(for: workingCopy))
    }

    private func storageKey(for workingCopy: SvnDockWorkingCopy) -> String {
        // Include the root as well as the registration ID. Reusing an ID at a
        // different location must never apply another copy's commit choices.
        let root = Data(workingCopy.rootURL.standardizedFileURL.path.utf8).base64EncodedString()
        return "SvnDock.commitDraft.v1.\(workingCopy.id.uuidString).\(root)"
    }
}
