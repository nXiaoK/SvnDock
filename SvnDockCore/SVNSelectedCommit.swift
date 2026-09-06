import Foundation

public enum SVNSelectedCommitError: Error, LocalizedError, Equatable, Sendable {
    case changedSelection(String)
    case missingParent(String)
    case externalWorkingCopy(String)
    case switchedTarget(String)
    case repositoryIdentityChanged
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .changedSelection(path):
            "“\(path)”的状态已变化或无法单独提交。未执行提交，请刷新并重新检查勾选范围。"
        case let .missingParent(path):
            "本次提交依赖尚未提交的父目录“\(path)”。请同时勾选该目录，再检查需要包含的子项。未执行提交。"
        case let .externalWorkingCopy(path):
            "“\(path)”属于 SVN 外部定义。请在其对应的工作副本中单独检查并提交，本次未执行提交。"
        case let .switchedTarget(path):
            "“\(path)”位于已切换分支的子树中，实际提交地址与根工作副本不同。已停止整个提交；请在目标分支的独立工作副本中检查并提交。"
        case .repositoryIdentityChanged:
            "工作副本的仓库地址或身份已变化，或无法确认本次审阅的目标。未执行提交，请关闭提交窗口，刷新工作副本后重新检查仓库地址与勾选范围。"
        case let .commandFailed(message):
            message
        }
    }
}

/// Commits explicit nodes without recursively adding unselected local edits.
/// Directory deletion and repository-side copies retain SVN's tree semantics.
/// The caller holds the working-copy scheduler and filesystem lock throughout.
public struct SVNSelectedCommit: Sendable {
    private let builder: SVNCommandBuilder
    private let runner: any ProcessRunning

    public init(executableURL: URL, runner: any ProcessRunning = ProcessRunner()) throws {
        builder = try SVNCommandBuilder(executableURL: executableURL)
        self.runner = runner
    }

    public func targets(for paths: [String], in workingCopy: WorkingCopy) throws -> [String] {
        Array(Set(try builder.normalizedLocalPaths(paths, in: workingCopy, command: "commit"))).sorted()
    }

    public func run(targets: [String], message: String, in workingCopy: WorkingCopy) async throws {
        let targets = try self.targets(for: targets, in: workingCopy)
        // Construct before reading so malformed messages and paths fail early.
        let invocation = try builder.makeInvocation(
            for: .commit(paths: targets, message: message, keepLocks: false, depth: .empty),
            in: workingCopy
        )
        let result = try await checkedRun(.status(SVNStatusOptions()), in: workingCopy)
        let entries = try SVNXMLParser.parseStatus(
            result.standardOutput, workingCopyURL: workingCopy.localPath, resolveNodeKinds: false
        )
        var indexed: [String: StatusEntry] = [:]
        let paths = entries.isEmpty ? [] : try builder.normalizedLocalPaths(
            entries.map(\.path), in: workingCopy, command: "commit"
        )
        for (path, entry) in zip(paths, entries) {
            indexed[path] = entry
        }
        let switchedPaths = Set(zip(paths, entries).compactMap { $0.1.isSwitched ? $0.0 : nil })
        let included = Set(targets)
        for target in targets {
            var switchedAncestor = target
            while true {
                if switchedPaths.contains(switchedAncestor) {
                    throw SVNSelectedCommitError.switchedTarget(target)
                }
                if switchedAncestor == "." { break }
                let parent = (switchedAncestor as NSString).deletingLastPathComponent
                switchedAncestor = parent.isEmpty ? "." : parent
            }
            if indexed[target]?.isFileExternal == true {
                throw SVNSelectedCommitError.externalWorkingCopy(target)
            }
            guard let entry = indexed[target], Self.canCommit(entry) else {
                throw SVNSelectedCommitError.changedSelection(target)
            }
            var parent = target
            while parent != "." {
                let component = (parent as NSString).deletingLastPathComponent
                parent = component.isEmpty ? "." : component
                if let ancestor = indexed[parent] {
                    if ancestor.status == .external {
                        throw SVNSelectedCommitError.externalWorkingCopy(target)
                    }
                    if (ancestor.status == .added || ancestor.status == .replaced),
                       !included.contains(parent) {
                        throw SVNSelectedCommitError.missingParent(parent)
                    }
                }
            }
        }
        // Bind an explicitly reviewed repository identity to the final write,
        // rather than trusting a registration ID or a refreshed service cache.
        if workingCopy.repositoryURL != nil || workingCopy.repositoryUUID != nil {
            let infoResult = try await checkedRun(.info, in: workingCopy)
            let info = try SVNXMLParser.parseInfo(infoResult.standardOutput)
            guard let expectedURL = workingCopy.repositoryURL,
                  let expectedUUID = workingCopy.repositoryUUID,
                  info.url == expectedURL, info.repositoryUUID == expectedUUID,
                  info.workingCopyRootURL?.resolvingSymlinksInPath().standardizedFileURL.path
                    == workingCopy.localPath.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw SVNSelectedCommitError.repositoryIdentityChanged
            }
        }
        try Task.checkCancellation()
        // Revalidate symlinks immediately before writing, after the status read.
        let root = workingCopy.localPath.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        for target in targets {
            let path = workingCopy.localPath.appendingPathComponent(target)
                .resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard path.starts(with: root) else {
                throw SVNCommandBuilderError.pathOutsideWorkingCopy(target)
            }
        }
        let committed = try await runner.run(invocation)
        guard committed.succeeded else {
            throw SVNSelectedCommitError.commandFailed(committed.standardErrorString)
        }
    }

    private static func canCommit(_ entry: StatusEntry) -> Bool {
        guard !entry.isTreeConflicted, entry.propertyStatus != .conflicted else { return false }
        switch entry.status {
        case .modified, .merged, .added, .deleted, .replaced: return true
        case .normal, .none: return entry.propertyStatus == .modified
        default: return false
        }
    }

    private func checkedRun(_ operation: SVNOperationKind, in workingCopy: WorkingCopy) async throws -> ProcessResult {
        try Task.checkCancellation()
        let result = try await runner.run(builder.makeInvocation(for: operation, in: workingCopy))
        guard result.succeeded else { throw SVNSelectedCommitError.commandFailed(result.standardErrorString) }
        return result
    }
}
