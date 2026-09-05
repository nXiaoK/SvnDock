import Foundation
import Darwin

public enum SVNMissingDeletionError: Error, LocalizedError, Equatable, Sendable {
    case workingCopyRoot
    case notMissing(String)
    case notCommitted(String)
    case conflicted(String)
    case differentWorkingCopy(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .workingCopyRoot:
            "不能将工作副本根目录标记为删除，请选择其中缺失的文件或目录。"
        case let .notMissing(path):
            "“\(path)”已不再是本地缺失状态，请刷新后重试。未标记删除。"
        case let .notCommitted(path):
            "“\(path)”不是已提交的正常纳管项目。尚未提交的新增项目请使用“清理缺失的添加记录”。未标记删除。"
        case let .conflicted(path):
            "“\(path)”存在冲突，请先解决冲突。未标记删除。"
        case let .differentWorkingCopy(path):
            "“\(path)”属于另一个工作副本，请在对应工作副本中操作。未标记删除。"
        case let .commandFailed(message):
            message
        }
    }
}

/// Schedules deletion of verified, already-versioned missing nodes. The caller
/// must hold its working-copy scheduler/lock throughout validation and mutation.
public struct SVNMissingDeletion: Sendable {
    private let builder: SVNCommandBuilder
    private let runner: any ProcessRunning

    public init(executableURL: URL, runner: any ProcessRunning = ProcessRunner()) throws {
        builder = try SVNCommandBuilder(executableURL: executableURL)
        self.runner = runner
    }

    public func targets(for paths: [String], in workingCopy: WorkingCopy) throws -> [String] {
        let normalized = Set(try builder.normalizedLocalPaths(paths, in: workingCopy, command: "delete"))
        guard !normalized.contains(".") else { throw SVNMissingDeletionError.workingCopyRoot }
        return normalized.filter { path in
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if normalized.contains(parent) { return false }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }.sorted()
    }

    public func run(targets: [String], in workingCopy: WorkingCopy) async throws {
        let targets = try self.targets(for: targets, in: workingCopy)
        try validateMissingBoundary(targets, in: workingCopy)
        var statuses: [String: StatusEntry] = [:]
        // status has no --targets option. Bound argv while completing the
        // entire selection's preflight before issuing one delete operation.
        var batch: [String] = []
        var bytes = 0
        for target in targets {
            let size = target.utf8.count + 1
            if !batch.isEmpty && (batch.count >= 256 || bytes + size > 64_000) {
                try await loadStatuses(batch, in: workingCopy, into: &statuses)
                batch.removeAll(keepingCapacity: true)
                bytes = 0
            }
            batch.append(target)
            bytes += size
        }
        if !batch.isEmpty { try await loadStatuses(batch, in: workingCopy, into: &statuses) }

        try Task.checkCancellation()
        let selectedRoots = Set(targets)
        for path in statuses.keys {
            var ancestor = path
            while !ancestor.isEmpty && !selectedRoots.contains(ancestor) {
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
            guard !ancestor.isEmpty else { throw SVNMissingDeletionError.differentWorkingCopy(path) }
        }
        // A missing directory can still contain conflicting, added or replaced
        // metadata. Inspect every reported descendant before recursive delete;
        // --keep-local deliberately does not reject all such local changes.
        let validationTargets = selectedRoots.union(statuses.keys).sorted()
        let result = try await checkedRun(.infoTargets(paths: validationTargets), in: workingCopy)
        let root = workingCopy.localPath.resolvingSymlinksInPath().standardizedFileURL
        var infos: [String: SVNInfo] = [:]
        let parsedInfos = try SVNXMLParser.parseInfos(result.standardOutput)
        if !parsedInfos.isEmpty {
            let infoPaths = try builder.normalizedLocalPaths(parsedInfos.map(\.path), in: workingCopy, command: "delete")
            for (path, info) in zip(infoPaths, parsedInfos) { infos[path] = info }
        }
        for target in validationTargets {
            guard let status = statuses[target], status.status == .missing else {
                throw SVNMissingDeletionError.notMissing(target)
            }
            guard !status.isTreeConflicted, status.propertyStatus != .conflicted else {
                throw SVNMissingDeletionError.conflicted(target)
            }
            // A pending copied subtree's child can report schedule=normal and
            // an info revision inherited from its source. Its status has no
            // BASE revision. Require both the schedule and an existing BASE.
            guard let info = infos[target], info.schedule == "normal",
                  let revision = status.revision, revision >= 0, !status.isCopied else {
                throw SVNMissingDeletionError.notCommitted(target)
            }
            guard info.workingCopyRootURL?.resolvingSymlinksInPath().standardizedFileURL == root else {
                throw SVNMissingDeletionError.differentWorkingCopy(target)
            }
        }
        try Task.checkCancellation()
        // Catch files restored while status/info was running. --keep-local
        // additionally preserves content recreated after this final check.
        try validateMissingBoundary(targets, in: workingCopy)
        _ = try await checkedRun(.delete(paths: targets), in: workingCopy)
    }

    private func loadStatuses(
        _ targets: [String], in workingCopy: WorkingCopy, into statuses: inout [String: StatusEntry]
    ) async throws {
        try Task.checkCancellation()
        let result = try await checkedRun(.status(SVNStatusOptions(depth: .infinity, paths: targets)), in: workingCopy)
        let entries = try SVNXMLParser.parseStatus(
            result.standardOutput, workingCopyURL: workingCopy.localPath, resolveNodeKinds: false
        )
        if !entries.isEmpty {
            let paths = try builder.normalizedLocalPaths(entries.map(\.path), in: workingCopy, command: "delete")
            for (path, entry) in zip(paths, entries) { statuses[path] = entry }
        }
    }

    private func validateMissingBoundary(_ targets: [String], in workingCopy: WorkingCopy) throws {
        let root = workingCopy.localPath.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        for target in targets {
            let url = workingCopy.localPath.appendingPathComponent(target).standardizedFileURL
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard resolved.starts(with: root), resolved.count > root.count else {
                throw SVNCommandBuilderError.pathOutsideWorkingCopy(target)
            }
            // lstat also sees dangling symlinks; fileExists would mistake them
            // for missing paths. Permission errors are never proof of absence.
            var metadata = stat()
            let isMissing = url.path.withCString { path in
                lstat(path, &metadata) == -1 && errno == ENOENT
            }
            guard isMissing else { throw SVNMissingDeletionError.notMissing(target) }
        }
    }

    private func checkedRun(_ operation: SVNOperationKind, in workingCopy: WorkingCopy) async throws -> ProcessResult {
        let result = try await runner.run(builder.makeInvocation(for: operation, in: workingCopy))
        guard result.succeeded else { throw SVNMissingDeletionError.commandFailed(result.standardErrorString) }
        return result
    }
}
