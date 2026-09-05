import Foundation

public enum SVNAdditionUndoError: Error, LocalizedError, Equatable, Sendable {
    case notScheduledAddition(String)
    case notMissing(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .notScheduledAddition(path):
            "“\(path)”不是尚未提交的待添加项目。已纳管文件缺失时，请恢复文件或明确标记为 SVN 删除。未执行清理。"
        case let .notMissing(path):
            "“\(path)”已不再是本地缺失状态，请刷新后重试。未执行清理。"
        case let .commandFailed(message):
            message
        }
    }
}

/// Cancels only verified pending additions. The caller must hold its working
/// copy scheduler/lock through this operation and validate the resolved boundary.
public struct SVNAdditionUndo: Sendable {
    private let builder: SVNCommandBuilder
    private let runner: any ProcessRunning

    public init(executableURL: URL, runner: any ProcessRunning = ProcessRunner()) throws {
        builder = try SVNCommandBuilder(executableURL: executableURL)
        self.runner = runner
    }

    public func targets(for paths: [String], in workingCopy: WorkingCopy) throws -> [String] {
        let normalized = Set(try builder.normalizedLocalPaths(paths, in: workingCopy))
        if normalized.contains(".") { return ["."] }
        return normalized.filter { path in
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if normalized.contains(parent) { return false }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }.sorted()
    }

    public func run(
        targets: [String],
        in workingCopy: WorkingCopy,
        missingOnly: Bool
    ) async throws {
        let targets = try self.targets(for: targets, in: workingCopy)
        try validateBoundary(targets, in: workingCopy)
        var statuses: [String: StatusEntry] = [:]
        // `svn status` has no --targets support. Bound each read by count and
        // bytes, but complete every validation before issuing a single revert.
        var batches: [[String]] = []
        var batch: [String] = []
        var bytes = 0
        for target in targets {
            let size = target.utf8.count + 1
            if !batch.isEmpty && (batch.count >= 256 || bytes + size > 64_000) {
                batches.append(batch)
                batch = []
                bytes = 0
            }
            batch.append(target)
            bytes += size
        }
        if !batch.isEmpty { batches.append(batch) }

        for batch in batches {
            try Task.checkCancellation()
            let result = try await checkedRun(.status(SVNStatusOptions(depth: .empty, paths: batch)), in: workingCopy)
            for entry in try SVNXMLParser.parseStatus(
                result.standardOutput, workingCopyURL: workingCopy.localPath, resolveNodeKinds: false
            ) {
                statuses[entry.fileURL(relativeTo: workingCopy).standardizedFileURL.path] = entry
            }
        }
        let result = try await checkedRun(.infoTargets(paths: targets), in: workingCopy)
        var infos: [String: SVNInfo] = [:]
        for info in try SVNXMLParser.parseInfos(result.standardOutput) {
            infos[absolutePath(info.path, in: workingCopy)] = info
        }
        for target in targets {
            let key = absolutePath(target, in: workingCopy)
            guard let info = infos[key], info.schedule == "add",
                  let status = statuses[key],
                  !status.isTreeConflicted,
                  status.propertyStatus != .conflicted,
                  status.status == (missingOnly ? .missing : .added) else {
                if missingOnly, let status = statuses[key], status.status != .missing {
                    throw SVNAdditionUndoError.notMissing(target)
                }
                throw SVNAdditionUndoError.notScheduledAddition(target)
            }
        }
        try Task.checkCancellation()
        try validateBoundary(targets, in: workingCopy)
        _ = try await checkedRun(.revert(paths: targets, depth: .infinity), in: workingCopy)
    }

    private func validateBoundary(_ targets: [String], in workingCopy: WorkingCopy) throws {
        let root = workingCopy.localPath.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        for target in targets {
            let resolved = workingCopy.localPath.appendingPathComponent(target)
                .resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard resolved.starts(with: root) else {
                throw SVNCommandBuilderError.pathOutsideWorkingCopy(target)
            }
        }
    }

    private func absolutePath(_ path: String, in workingCopy: WorkingCopy) -> String {
        (path.hasPrefix("/") ? URL(fileURLWithPath: path) : workingCopy.localPath.appendingPathComponent(path))
            .standardizedFileURL.path
    }

    private func checkedRun(_ operation: SVNOperationKind, in workingCopy: WorkingCopy) async throws -> ProcessResult {
        let result = try await runner.run(builder.makeInvocation(for: operation, in: workingCopy))
        guard result.succeeded else {
            throw SVNAdditionUndoError.commandFailed(result.standardErrorString)
        }
        return result
    }
}
