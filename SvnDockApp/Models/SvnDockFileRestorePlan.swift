import Foundation
import SvnDockCore

struct SvnDockFileRestorePlan: Equatable, Sendable {
    let workingCopy: SvnDockWorkingCopy
    let relativePath: String
    let beforeRevision: Int
    let baseRevision: Int
    let sourceURL: URL
    let historicalURL: URL
    let repositoryUUID: String

    var targetRevision: Int { beforeRevision - 1 }

    static func parseRevision(_ input: String) -> Int? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "r" || text.first == "R" { text.removeFirst() }
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(text), value > 0 else { return nil }
        return value
    }
}

struct SvnDockFileRestoreRequest: Identifiable, Sendable {
    let id = UUID()
    let workingCopy: SvnDockWorkingCopy
    let entry: SvnDockStatusEntry
    let finderClaim: FinderCommandClaim?
}
