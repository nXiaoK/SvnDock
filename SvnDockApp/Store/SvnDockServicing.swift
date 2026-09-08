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
    func refreshFinderBadges(for workingCopy: SvnDockWorkingCopy, directoryPaths: [String], preferredPaths: [String]) async throws
    func finderTarget(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> SvnDockFinderTarget
    func refreshWorkingCopyMetadata(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockWorkingCopy
    func checkRemoteStatus(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockRemoteStatusSnapshot
    func directoryChildren(
        relativePath: String,
        in workingCopy: SvnDockWorkingCopy
    ) async throws -> [SvnDockStatusEntry]
    func diff(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> String
    func classifyLocalDifference(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> SVNLocalDifferenceKind
    func history(
        for workingCopy: SvnDockWorkingCopy,
        relativePaths: [String],
        limit: Int
    ) async throws -> [SvnDockLogEntry]
    func historyPage(
        for workingCopy: SvnDockWorkingCopy,
        relativePaths: [String],
        limit: Int,
        beforeRevision: Int?
    ) async throws -> [SvnDockLogEntry]
    func revisionDetails(revision: Int, in workingCopy: SvnDockWorkingCopy) async throws -> SVNRevisionDetails
    func revisionDiff(revision: Int, change: SVNChangedPath, repositoryRoot: URL,
                      in workingCopy: SvnDockWorkingCopy) async throws -> String

    func update(workingCopies: [SvnDockWorkingCopy]) async throws
    func update(
        workingCopies: [SvnDockWorkingCopy],
        progress: @escaping @Sendable (SVNProgressSnapshot) -> Void
    ) async throws
    func commit(
        workingCopy: SvnDockWorkingCopy,
        relativePaths: [String],
        message: String
    ) async throws
    func commit(
        workingCopy: SvnDockWorkingCopy,
        relativePaths: [String],
        message: String,
        progress: @escaping @Sendable (SVNProgressSnapshot) -> Void
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
    func prepareFileRestore(relativePath: String, beforeRevision: Int, in workingCopy: SvnDockWorkingCopy) async throws -> SvnDockFileRestorePlan
    func restoreFile(_ plan: SvnDockFileRestorePlan) async throws
    func resolve(
        relativePaths: [String],
        using resolution: SvnDockConflictResolution,
        in workingCopy: SvnDockWorkingCopy
    ) async throws
    func prepareIgnoreRecommendations(in workingCopy: SvnDockWorkingCopy) async throws -> SvnDockIgnoreRecommendationPlan
    func applyIgnoreRecommendations(_ plan: SvnDockIgnoreRecommendationPlan, selectedIDs: Set<String>) async throws
    func addIgnoreRules(
        _ rules: [SvnDockIgnoreRule],
        in workingCopy: SvnDockWorkingCopy
    ) async throws
    func ignoredEntries(for workingCopy: SvnDockWorkingCopy) async throws -> [SvnDockStatusEntry]
    func prepareIgnoreRemoval(for entry: SvnDockStatusEntry, in workingCopy: SvnDockWorkingCopy) async throws -> SvnDockIgnoreRemovalPlan
    func removeIgnoreRule(_ plan: SvnDockIgnoreRemovalPlan, in workingCopy: SvnDockWorkingCopy) async throws
    func cleanup(workingCopy: SvnDockWorkingCopy) async throws
}

extension SvnDockServicing {
    func prepareFileRestore(relativePath: String, beforeRevision: Int, in workingCopy: SvnDockWorkingCopy) async throws -> SvnDockFileRestorePlan {
        throw SvnDockServiceError.unavailable("当前服务不支持还原历史版本。")
    }

    func restoreFile(_ plan: SvnDockFileRestorePlan) async throws {
        throw SvnDockServiceError.unavailable("当前服务不支持还原历史版本。")
    }

    func update(
        workingCopies: [SvnDockWorkingCopy],
        progress: @escaping @Sendable (SVNProgressSnapshot) -> Void
    ) async throws {
        progress(SVNProgressSnapshot())
        try await update(workingCopies: workingCopies)
    }

    func commit(
        workingCopy: SvnDockWorkingCopy,
        relativePaths: [String],
        message: String,
        progress: @escaping @Sendable (SVNProgressSnapshot) -> Void
    ) async throws {
        progress(SVNProgressSnapshot())
        try await commit(workingCopy: workingCopy, relativePaths: relativePaths, message: message)
    }

    func classifyLocalDifference(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> SVNLocalDifferenceKind {
        throw SvnDockServiceError.unavailable("当前服务不支持识别仅换行或空白变化。")
    }

    func prepareIgnoreRecommendations(in workingCopy: SvnDockWorkingCopy) async throws -> SvnDockIgnoreRecommendationPlan {
        throw SvnDockServiceError.unavailable("当前服务不支持推荐忽略项。")
    }

    func applyIgnoreRecommendations(_ plan: SvnDockIgnoreRecommendationPlan, selectedIDs: Set<String>) async throws {
        throw SvnDockServiceError.unavailable("当前服务不支持推荐忽略项。")
    }

    func finderTarget(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> SvnDockFinderTarget {
        throw SvnDockServiceError.unavailable("当前服务不支持读取 Finder 所选项目。")
    }

    func refreshFinderBadges(for workingCopy: SvnDockWorkingCopy, directoryPaths: [String]) async throws {
        try await refreshFinderBadges(for: workingCopy, directoryPaths: directoryPaths, preferredPaths: [])
    }

    func refreshFinderBadges(for workingCopy: SvnDockWorkingCopy, directoryPaths: [String], preferredPaths: [String]) async throws {
        throw SvnDockServiceError.unavailable("当前服务不支持后台刷新 Finder 状态。")
    }

    func ignoredEntries(for workingCopy: SvnDockWorkingCopy) async throws -> [SvnDockStatusEntry] {
        throw SvnDockServiceError.unavailable("当前服务不支持查看已忽略项目。")
    }

    func prepareIgnoreRemoval(for entry: SvnDockStatusEntry, in workingCopy: SvnDockWorkingCopy) async throws -> SvnDockIgnoreRemovalPlan {
        throw SvnDockServiceError.unavailable("当前服务不支持移除忽略规则。")
    }

    func removeIgnoreRule(_ plan: SvnDockIgnoreRemovalPlan, in workingCopy: SvnDockWorkingCopy) async throws {
        throw SvnDockServiceError.unavailable("当前服务不支持移除忽略规则。")
    }

    func historyPage(
        for workingCopy: SvnDockWorkingCopy,
        relativePaths: [String],
        limit: Int,
        beforeRevision: Int?
    ) async throws -> [SvnDockLogEntry] {
        guard beforeRevision == nil else {
            throw SvnDockServiceError.unavailable("当前服务不支持加载更早的提交历史。")
        }
        return try await history(for: workingCopy, relativePaths: relativePaths, limit: limit)
    }

    func refreshWorkingCopyMetadata(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockWorkingCopy {
        workingCopy
    }

    func checkRemoteStatus(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockRemoteStatusSnapshot {
        throw SvnDockServiceError.unavailable("当前服务不支持检查服务器更新。")
    }
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
