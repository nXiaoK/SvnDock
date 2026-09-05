import Foundation
import SvnDockCore

/// Deterministic data source for previews and UI tests. The shipping app should
/// inject the SvnDockCore-backed service from `SvnDockApp.swift`.
actor MockSvnDockService: SvnDockServicing {
    private var workingCopies: [SvnDockWorkingCopy]
    private var entriesByWorkingCopyID: [UUID: [SvnDockStatusEntry]]

    init(
        workingCopies: [SvnDockWorkingCopy] = [],
        entriesByWorkingCopyID: [UUID: [SvnDockStatusEntry]] = [:]
    ) {
        self.workingCopies = workingCopies
        self.entriesByWorkingCopyID = entriesByWorkingCopyID
    }

    func loadRegisteredWorkingCopies() async throws -> [SvnDockWorkingCopy] {
        await briefDelay()
        return workingCopies
    }

    func registerWorkingCopy(at url: URL) async throws -> SvnDockWorkingCopy {
        await briefDelay()
        if let existing = workingCopies.first(where: { $0.rootURL.standardizedFileURL == url.standardizedFileURL }) {
            return existing
        }

        let copy = SvnDockWorkingCopy(name: url.lastPathComponent, rootURL: url)
        workingCopies.append(copy)
        entriesByWorkingCopyID[copy.id] = []
        return copy
    }

    func unregisterWorkingCopy(id: UUID) async throws {
        await briefDelay()
        workingCopies.removeAll { $0.id == id }
        entriesByWorkingCopyID[id] = nil
    }

    func status(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockStatusSnapshot {
        await briefDelay()
        return SvnDockStatusSnapshot(
            entries: entriesByWorkingCopyID[workingCopy.id, default: []]
        )
    }

    func directoryChildren(
        relativePath: String,
        in workingCopy: SvnDockWorkingCopy
    ) async throws -> [SvnDockStatusEntry] {
        await briefDelay()
        let prefix = relativePath == "." ? "" : relativePath + "/"
        return entriesByWorkingCopyID[workingCopy.id, default: []]
            .filter { entry in
                guard entry.relativePath.hasPrefix(prefix) else { return false }
                return !entry.relativePath.dropFirst(prefix.count).contains("/")
            }
            .sorted {
                if $0.nodeKind != $1.nodeKind {
                    return $0.nodeKind == .directory
                }
                return $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
            }
    }

    func diff(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> String {
        await briefDelay()
        return Self.exampleDiff(relativePath: relativePath)
    }

    func history(
        for workingCopy: SvnDockWorkingCopy,
        relativePaths: [String],
        limit: Int
    ) async throws -> [SvnDockLogEntry] {
        await briefDelay()
        return Array(Self.exampleHistory.prefix(limit))
    }

    func revisionDetails(revision: Int, in workingCopy: SvnDockWorkingCopy) async throws -> SVNRevisionDetails {
        await briefDelay()
        let historical = Self.exampleHistory.first { $0.revision == revision }
        return SVNRevisionDetails(
            repositoryRootURL: URL(string: "https://svn.example.com/project")!,
            entry: SVNLogEntry(revision: revision, author: historical?.author ?? "xiaok",
                               date: historical?.date ?? Date(timeIntervalSince1970: 1_788_573_600),
                               message: historical?.message ?? "完善支付接口文档与参数校验\n补充中文说明，整理错误返回。"),
            changes: [
                .init(path: "/trunk/docs/API.md", action: .modified, kind: .file),
                .init(path: "/trunk/src/payment.ts", action: .modified, kind: .file),
                .init(path: "/trunk/docs/使用说明.md", action: .added, kind: .file),
                .init(path: "/trunk/docs/legacy.md", action: .deleted, kind: .file),
                .init(path: "/trunk/src/client.ts", action: .added, kind: .file,
                      copyFromPath: "/trunk/src/request.ts", copyFromRevision: max(0, revision - 1), isMove: true),
                .init(path: "/trunk/assets/logo.png", action: .modified, kind: .file),
                .init(path: "/trunk/docs", action: .modified, kind: .directory)
            ]
        )
    }

    func revisionDiff(revision: Int, change: SVNChangedPath, repositoryRoot: URL,
                      in workingCopy: SvnDockWorkingCopy) async throws -> String {
        await briefDelay()
        if change.kind == .directory {
            return "Property changes on: \(change.path)\nAdded: svn:ignore\n## -0,0 +1 ##\n+*.tmp\n"
        }
        if change.path.hasSuffix(".png") { return "Cannot display: file marked as a binary type.\nsvn:mime-type = image/png\n" }
        switch change.action {
        case .added:
            if change.comparesCopySource { return "" }
            return "@@ -0,0 +1,2 @@\n+# 使用说明\n+新增支付接口使用指南。\n"
        case .deleted: return "@@ -1,2 +0,0 @@\n-# 旧版接口\n-本接口已弃用。\n"
        default:
            return "--- \(change.path)\t(revision \(revision - 1))\n+++ \(change.path)\t(revision \(revision))\n@@ -4,3 +4,4 @@\n ## 支付接口\n-旧版参数说明\n+补充中文参数说明\n+新增错误码与处理建议\n 示例：\n@@ -28,2 +29,2 @@\n-返回通用错误\n+返回明确的参数校验结果\n 请求结束。\n"
        }
    }

    func update(workingCopies: [SvnDockWorkingCopy]) async throws {
        await operationDelay()
    }

    func commit(
        workingCopy: SvnDockWorkingCopy,
        relativePaths: [String],
        message: String
    ) async throws {
        await operationDelay()
        entriesByWorkingCopyID[workingCopy.id]?.removeAll { relativePaths.contains($0.relativePath) }
    }

    func add(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws {
        await briefDelay()
        guard var entries = entriesByWorkingCopyID[workingCopy.id] else { return }
        for index in entries.indices where relativePaths.contains(entries[index].relativePath) {
            entries[index].status = .added
        }
        entriesByWorkingCopyID[workingCopy.id] = entries
    }

    func unscheduleAdd(
        relativePaths: [String],
        in workingCopy: SvnDockWorkingCopy
    ) async throws {
        await briefDelay()
        guard var entries = entriesByWorkingCopyID[workingCopy.id] else { return }
        let targets = Self.collapsingDescendantPaths(relativePaths)
        guard !targets.isEmpty, targets.allSatisfy({ target in
            entries.contains {
                $0.relativePath == target && $0.status == .added
            }
        }) else {
            throw SvnDockServiceError.noScheduledAdditions
        }

        for index in entries.indices where entries[index].status == .added {
            if targets.contains(where: {
                Self.path(entries[index].relativePath, isInside: $0)
            }) {
                entries[index].status = .unversioned
            }
        }
        entriesByWorkingCopyID[workingCopy.id] = entries
    }

    func cleanupMissingAdditions(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws {
        await briefDelay()
        entriesByWorkingCopyID[workingCopy.id]?.removeAll { entry in
            entry.status == .missing && relativePaths.contains { target in
                entry.relativePath == target || entry.relativePath.hasPrefix(target + "/")
            }
        }
    }

    func revert(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws {
        await briefDelay()
        entriesByWorkingCopyID[workingCopy.id]?.removeAll { relativePaths.contains($0.relativePath) }
    }

    func resolve(
        relativePaths: [String],
        using resolution: SvnDockConflictResolution,
        in workingCopy: SvnDockWorkingCopy
    ) async throws {
        await briefDelay()
        guard var entries = entriesByWorkingCopyID[workingCopy.id] else { return }
        for index in entries.indices where relativePaths.contains(entries[index].relativePath) {
            entries[index].status = .modified
            entries[index].conflictKinds = []
        }
        entriesByWorkingCopyID[workingCopy.id] = entries
    }

    func addIgnoreRules(
        _ rules: [SvnDockIgnoreRule],
        in workingCopy: SvnDockWorkingCopy
    ) async throws {
        await briefDelay()
        let ignoredNames = Set(rules.map(\.pattern))
        entriesByWorkingCopyID[workingCopy.id]?.removeAll {
            $0.status == .unversioned && ignoredNames.contains($0.fileName)
        }
    }

    func cleanup(workingCopy: SvnDockWorkingCopy) async throws {
        await operationDelay()
    }

    private func briefDelay() async {
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    private func operationDelay() async {
        try? await Task.sleep(nanoseconds: 450_000_000)
    }

    private static func collapsingDescendantPaths(_ paths: [String]) -> [String] {
        let sorted = Set(paths).sorted {
            let lhsDepth = ($0 as NSString).pathComponents.count
            let rhsDepth = ($1 as NSString).pathComponents.count
            return lhsDepth == rhsDepth ? $0 < $1 : lhsDepth < rhsDepth
        }
        return sorted.reduce(into: []) { result, path in
            guard !result.contains(where: { Self.path(path, isInside: $0) }) else {
                return
            }
            result.append(path)
        }
    }

    private static func path(_ candidate: String, isInside root: String) -> Bool {
        root == "." || candidate == root || candidate.hasPrefix(root + "/")
    }

    static func preview() -> MockSvnDockService {
        let appID = UUID()
        let docsID = UUID()
        let appCopy = SvnDockWorkingCopy(
            id: appID,
            name: "SvnDock",
            rootURL: URL(fileURLWithPath: "/Users/Shared/Projects/SvnDock"),
            repositoryURL: URL(string: "https://svn.example.com/repos/SvnDock/trunk"),
            revision: 1842,
            lastRefreshedAt: .now,
            counts: SvnDockStatusCounts(changed: 4, conflicts: 1, unversioned: 1)
        )
        let docsCopy = SvnDockWorkingCopy(
            id: docsID,
            name: "ProductDocs",
            rootURL: URL(fileURLWithPath: "/Users/Shared/Projects/ProductDocs"),
            repositoryURL: URL(string: "https://svn.example.com/repos/docs/trunk"),
            revision: 617,
            lastRefreshedAt: .now.addingTimeInterval(-860),
            counts: SvnDockStatusCounts(changed: 2, conflicts: 0, unversioned: 0)
        )

        let now = Date.now
        let appEntries = [
            SvnDockStatusEntry(
                workingCopyID: appID,
                relativePath: "SvnDockApp/Views/WorkingCopySidebar.swift",
                nodeKind: .file,
                status: .modified,
                fileSize: 8_496,
                modifiedAt: now.addingTimeInterval(-125)
            ),
            SvnDockStatusEntry(
                workingCopyID: appID,
                relativePath: "SvnDockApp/Views/CommitSheet.swift",
                nodeKind: .file,
                status: .added,
                changelist: "UI",
                fileSize: 5_112,
                modifiedAt: now.addingTimeInterval(-380)
            ),
            SvnDockStatusEntry(
                workingCopyID: appID,
                relativePath: "SvnDockCore/SVNCommandBuilder.swift",
                nodeKind: .file,
                status: .conflicted,
                repositoryStatus: .modified,
                fileSize: 4_910,
                modifiedAt: now.addingTimeInterval(-740)
            ),
            SvnDockStatusEntry(
                workingCopyID: appID,
                relativePath: "README.md",
                nodeKind: .file,
                status: .modified,
                fileSize: 2_042,
                modifiedAt: now.addingTimeInterval(-1_440)
            ),
            SvnDockStatusEntry(
                workingCopyID: appID,
                relativePath: "notes/local-plan.txt",
                nodeKind: .file,
                status: .unversioned,
                fileSize: 931,
                modifiedAt: now.addingTimeInterval(-92)
            )
        ]
        let docsEntries = [
            SvnDockStatusEntry(
                workingCopyID: docsID,
                relativePath: "guides/install.md",
                nodeKind: .file,
                status: .modified,
                fileSize: 3_512,
                modifiedAt: now.addingTimeInterval(-650)
            ),
            SvnDockStatusEntry(
                workingCopyID: docsID,
                relativePath: "images/workflow.png",
                nodeKind: .file,
                status: .added,
                fileSize: 182_400,
                modifiedAt: now.addingTimeInterval(-760)
            )
        ]

        return MockSvnDockService(
            workingCopies: [appCopy, docsCopy],
            entriesByWorkingCopyID: [appID: appEntries, docsID: docsEntries]
        )
    }

    private static func exampleDiff(relativePath: String) -> String {
        """
        --- \(relativePath) (base)
        +++ \(relativePath) (working copy)
        @@ -18,4 +18,6 @@
         struct WorkingCopyView: View {
             let workingCopy: WorkingCopy
        -    var showsStatus = false
        +    // Keep the current SVN state visible in Finder and the app.
        +    var showsStatus = true
        +    var supportsMultipleWorkingCopies = true
         }
        """
    }

    private static let exampleHistory: [SvnDockLogEntry] = [
        SvnDockLogEntry(
            revision: 1842,
            author: "alice",
            date: Date.now.addingTimeInterval(-3_600),
            message: "完善 Finder 右键操作与队列恢复"
        ),
        SvnDockLogEntry(
            revision: 1841,
            author: "bob",
            date: Date.now.addingTimeInterval(-86_400),
            message: "修复多工作副本状态刷新"
        )
    ]
}
