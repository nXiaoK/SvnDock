import Foundation

/// Filters only the supplied log page collection. It performs no repository
/// query and cannot treat an empty result as absence from the full history.
struct SvnDockHistoryQuery: Equatable, Sendable {
    var text = ""
    var author = ""

    var isEmpty: Bool { normalizedText.isEmpty && normalizedAuthor.isEmpty }

    func filter(_ entries: [SvnDockLogEntry]) -> [SvnDockLogEntry] {
        let text = normalizedText
        let author = normalizedAuthor
        guard !text.isEmpty || !author.isEmpty else { return entries }
        return entries.filter { entry in
            let authorMatches = author.isEmpty || (entry.author ?? "").localizedStandardContains(author)
            let textMatches = text.isEmpty || entry.message.localizedStandardContains(text)
                || (entry.author ?? "").localizedStandardContains(text)
                || "r\(entry.revision)".localizedStandardContains(text)
            return authorMatches && textMatches
        }
    }

    /// Revision jumps accept a single positive numeric revision, never an SVN
    /// range or symbolic keyword. The detail loader validates its existence.
    static func revisionNumber(from input: String) -> Int? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("r") || text.hasPrefix("R") { text.removeFirst() }
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let revision = Int(text), revision > 0 else { return nil }
        return revision
    }

    static func visibleSelection(
        revision: Int?, selectedTargetID: String?, currentTargetID: String?,
        entries: [SvnDockLogEntry]
    ) -> Int? {
        guard let revision, let selectedTargetID, selectedTargetID == currentTargetID,
              entries.contains(where: { $0.revision == revision }) else { return nil }
        return revision
    }

    private var normalizedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var normalizedAuthor: String { author.trimmingCharacters(in: .whitespacesAndNewlines) }
}
