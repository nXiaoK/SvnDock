import Foundation

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
        @@ -18,6 +18,9 @@
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
