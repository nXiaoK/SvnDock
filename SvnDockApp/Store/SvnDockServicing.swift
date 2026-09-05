import Foundation
import SvnDockCore

/// Injectable boundary between the SwiftUI application and the SVN engine.
///
/// A concrete implementation may use SvnDockCore, XPC, or a deterministic
/// in-memory implementation for previews and UI tests.
protocol SvnDockServicing: Sendable {
    func loadRegisteredWorkingCopies() async throws -> [SvnDockWorkingCopy]
    func registerWorkingCopy(at url: URL) async throws -> SvnDockWorkingCopy
    func unregisterWorkingCopy(id: UUID) async throws

    func status(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockStatusSnapshot
    func directoryChildren(
        relativePath: String,
        in workingCopy: SvnDockWorkingCopy
    ) async throws -> [SvnDockStatusEntry]
    func diff(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> String
    func history(
        for workingCopy: SvnDockWorkingCopy,
        relativePaths: [String],
        limit: Int
    ) async throws -> [SvnDockLogEntry]
    func revisionDetails(revision: Int, in workingCopy: SvnDockWorkingCopy) async throws -> SVNRevisionDetails
    func revisionDiff(revision: Int, change: SVNChangedPath, repositoryRoot: URL,
                      in workingCopy: SvnDockWorkingCopy) async throws -> String

    func update(workingCopies: [SvnDockWorkingCopy]) async throws
    func commit(
        workingCopy: SvnDockWorkingCopy,
        relativePaths: [String],
        message: String
    ) async throws
    func add(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws
    func unscheduleAdd(
        relativePaths: [String],
        in workingCopy: SvnDockWorkingCopy
    ) async throws
    func cleanupMissingAdditions(
        relativePaths: [String],
        in workingCopy: SvnDockWorkingCopy
    ) async throws
    func scheduleMissingDeletion(
        relativePaths: [String],
        in workingCopy: SvnDockWorkingCopy
    ) async throws
    func revert(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws
    func resolve(
        relativePaths: [String],
        using resolution: SvnDockConflictResolution,
        in workingCopy: SvnDockWorkingCopy
    ) async throws
    func addIgnoreRules(
        _ rules: [SvnDockIgnoreRule],
        in workingCopy: SvnDockWorkingCopy
    ) async throws
    func cleanup(workingCopy: SvnDockWorkingCopy) async throws
}

enum SvnDockServiceError: LocalizedError {
    case notAWorkingCopy(URL)
    case noWorkingCopySelected
    case emptyCommitMessage
    case noCommittableFiles
    case noConflictedFiles
    case noScheduledAdditions
    case invalidIgnoreTarget(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .notAWorkingCopy(let url):
            "“\(url.lastPathComponent)”不是有效的 SVN 工作副本。"
        case .noWorkingCopySelected:
            "请先选择一个工作副本。"
        case .emptyCommitMessage:
            "提交说明不能为空。"
        case .noCommittableFiles:
            "没有可提交的文件。"
        case .noConflictedFiles:
            "所选项目已经没有可解决的冲突。"
        case .noScheduledAdditions:
            "所选项目已经不再处于待添加状态，请刷新后重试。"
        case .invalidIgnoreTarget(let message):
            message
        case .unavailable(let message):
            message
        }
    }
}
