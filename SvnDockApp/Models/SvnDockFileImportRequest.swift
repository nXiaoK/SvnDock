import Foundation

/// One presentation identity for both directory registration and history files.
/// Keep it until completion even after SwiftUI dismisses the system panel.
struct SvnDockFileImportRequest: Identifiable, Equatable, Sendable {
    enum Purpose: Equatable, Sendable {
        case workingCopies
        case historicalFile(SvnDockWorkingCopy)
    }

    let id = UUID()
    let purpose: Purpose

    var selectsDirectories: Bool {
        if case .workingCopies = purpose { return true }
        return false
    }
}
