import Combine
import Foundation

/// The items reported by SVN are notifications, not a total-work estimate:
/// a directory notification can cover thousands of descendants.
struct SvnDockTransferProgress: Equatable, Sendable {
    var operationID: UUID
    var kind: SvnDockOperationKind
    var phase: String
    var currentPath: String? = nil
    var processedItems = 0
    var selectedItemCount: Int? = nil
    var workingCopyName: String
    var completedWorkingCopies = 0
    var totalWorkingCopies = 1
    var startedAt: Date
}

/// Frequent transfer notifications must not invalidate the entire store's
/// status list or commit sheet. Only the small progress view observes this.
@MainActor
final class SvnDockTransferProgressModel: ObservableObject {
    @Published var snapshot: SvnDockTransferProgress?
}
