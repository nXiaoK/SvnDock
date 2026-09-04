import Foundation

/// A UI-facing summary of a registered SVN working copy.
///
/// The application target deliberately owns this small model so the SwiftUI
/// layer does not depend on the representation used by the command runner or
/// Finder extension. A production service can map `SvnDockCore.WorkingCopy`
/// into this value without leaking process concerns into the UI.
struct SvnDockWorkingCopy: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var rootURL: URL
    var repositoryURL: URL?
    var revision: Int?
    var lastRefreshedAt: Date?
    var counts: SvnDockStatusCounts

    init(
        id: UUID = UUID(),
        name: String,
        rootURL: URL,
        repositoryURL: URL? = nil,
        revision: Int? = nil,
        lastRefreshedAt: Date? = nil,
        counts: SvnDockStatusCounts = .zero
    ) {
        self.id = id
        self.name = name
        self.rootURL = rootURL
        self.repositoryURL = repositoryURL
        self.revision = revision
        self.lastRefreshedAt = lastRefreshedAt
        self.counts = counts
    }
}

struct SvnDockStatusCounts: Hashable, Sendable {
    var changed: Int
    var conflicts: Int
    var unversioned: Int

    static let zero = SvnDockStatusCounts(changed: 0, conflicts: 0, unversioned: 0)

    static func make(from entries: [SvnDockStatusEntry]) -> SvnDockStatusCounts {
        entries.reduce(into: .zero) { counts, entry in
            if entry.status.isChange {
                counts.changed += 1
            }
            if entry.status == .conflicted || entry.repositoryStatus == .conflicted {
                counts.conflicts += 1
            }
            if entry.status == .unversioned {
                counts.unversioned += 1
            }
        }
    }
}

enum SvnDockNodeKind: String, Hashable, Sendable {
    case file
    case directory
}

enum SvnDockConflictKind: String, Hashable, Sendable {
    case text
    case property
    case tree
}

enum SvnDockConflictResolution: String, CaseIterable, Identifiable, Sendable {
    case working
    case mineFull
    case theirsFull
    case base

    var id: Self { self }

    var displayName: String {
        switch self {
        case .working: "保留当前内容并标记已解决"
        case .mineFull: "使用更新前的本地版本"
        case .theirsFull: "使用仓库传入版本"
        case .base: "使用共同基线版本"
        }
    }
}

enum SvnDockIgnoreMode: Hashable, Sendable {
    case name
    case fileExtension
}

struct SvnDockIgnoreRule: Hashable, Sendable {
    let targetRelativePath: String
    let parentRelativePath: String
    let pattern: String
    let mode: SvnDockIgnoreMode
}

struct SvnDockLogEntry: Identifiable, Hashable, Sendable {
    let revision: Int
    let author: String?
    let date: Date?
    let message: String

    var id: Int { revision }
}

enum SvnDockHistoryTargetSource: String, Hashable, Sendable {
    case selection
    case finderExplicit
    case workingCopy
}

struct SvnDockHistoryTarget: Identifiable, Hashable, Sendable {
    let workingCopy: SvnDockWorkingCopy
    let relativePaths: [String]
    let title: String
    let source: SvnDockHistoryTargetSource

    var id: String {
        let paths = relativePaths.isEmpty ? "." : relativePaths.joined(separator: "\u{1F}")
        return "\(workingCopy.id.uuidString)::\(paths)::\(source.rawValue)"
    }
}

enum SvnDockStatusKind: String, CaseIterable, Hashable, Sendable {
    case modified
    case added
    case deleted
    case replaced
    case conflicted
    case unversioned
    case missing
    case ignored
    case external
    case obstructed
    case clean

    var displayName: String {
        switch self {
        case .modified: "已修改"
        case .added: "已添加"
        case .deleted: "已删除"
        case .replaced: "已替换"
        case .conflicted: "有冲突"
        case .unversioned: "未纳管"
        case .missing: "本地缺失"
        case .ignored: "已忽略"
        case .external: "外部定义"
        case .obstructed: "路径阻塞"
        case .clean: "未更改"
        }
    }

    var isChange: Bool {
        switch self {
        case .modified, .added, .deleted, .replaced, .conflicted, .missing, .obstructed:
            true
        case .unversioned, .ignored, .external, .clean:
            false
        }
    }

    var canCommit: Bool {
        switch self {
        case .modified, .added, .deleted, .replaced, .missing:
            true
        case .conflicted, .unversioned, .ignored, .external, .obstructed, .clean:
            false
        }
    }
}

struct SvnDockStatusEntry: Identifiable, Hashable, Sendable {
    var id: String { "\(workingCopyID.uuidString)::\(relativePath)" }

    let workingCopyID: UUID
    var relativePath: String
    var nodeKind: SvnDockNodeKind
    var status: SvnDockStatusKind
    var repositoryStatus: SvnDockStatusKind?
    var conflictKinds: Set<SvnDockConflictKind>
    var changelist: String?
    var lockOwner: String?
    var fileSize: Int64?
    var modifiedAt: Date?

    init(
        workingCopyID: UUID,
        relativePath: String,
        nodeKind: SvnDockNodeKind,
        status: SvnDockStatusKind,
        repositoryStatus: SvnDockStatusKind? = nil,
        conflictKinds: Set<SvnDockConflictKind>? = nil,
        changelist: String? = nil,
        lockOwner: String? = nil,
        fileSize: Int64? = nil,
        modifiedAt: Date? = nil
    ) {
        self.workingCopyID = workingCopyID
        self.relativePath = relativePath
        self.nodeKind = nodeKind
        self.status = status
        self.repositoryStatus = repositoryStatus
        self.conflictKinds = conflictKinds
            ?? (status == .conflicted ? [.text] : [])
        self.changelist = changelist
        self.lockOwner = lockOwner
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
    }

    var fileName: String {
        if relativePath == "." {
            return "工作副本根目录"
        }
        return URL(fileURLWithPath: relativePath).lastPathComponent
    }

    var parentPath: String {
        let value = URL(fileURLWithPath: relativePath).deletingLastPathComponent().path
        return value == "." || value == "/" ? "" : value
    }
}

/// Immutable, precomputed status data returned by a service refresh.
///
/// Sorting and indexing can be expensive for large working copies, so the
/// service builds this value on its actor before publishing it to SwiftUI.
struct SvnDockStatusSnapshot: Sendable {
    static let empty = SvnDockStatusSnapshot(entries: [])

    let entries: [SvnDockStatusEntry]
    let committableEntries: [SvnDockStatusEntry]
    let counts: SvnDockStatusCounts

    private let entryIndex: [SvnDockStatusEntry.ID: Int]

    init(entries unsortedEntries: [SvnDockStatusEntry]) {
        let entries = unsortedEntries.sorted(by: Self.statusSort)
        var entryIndex: [SvnDockStatusEntry.ID: Int] = [:]
        var committableEntries: [SvnDockStatusEntry] = []
        var counts = SvnDockStatusCounts.zero

        entryIndex.reserveCapacity(entries.count)
        committableEntries.reserveCapacity(entries.count)

        for (index, entry) in entries.enumerated() {
            let id = entry.id
            entryIndex[id] = index
            if entry.status.canCommit {
                committableEntries.append(entry)
            }
            if entry.status.isChange {
                counts.changed += 1
            }
            if entry.status == .conflicted || entry.repositoryStatus == .conflicted {
                counts.conflicts += 1
            }
            if entry.status == .unversioned {
                counts.unversioned += 1
            }
        }

        self.entries = entries
        self.entryIndex = entryIndex
        self.committableEntries = committableEntries
        self.counts = counts
    }

    func entry(withID id: SvnDockStatusEntry.ID) -> SvnDockStatusEntry? {
        guard let index = entryIndex[id] else { return nil }
        return entries[index]
    }

    func containsEntry(withID id: SvnDockStatusEntry.ID) -> Bool {
        entryIndex[id] != nil
    }

    private static func statusSort(
        _ lhs: SvnDockStatusEntry,
        _ rhs: SvnDockStatusEntry
    ) -> Bool {
        let lhsRank = statusRank(lhs.status)
        let rhsRank = statusRank(rhs.status)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
    }

    private static func statusRank(_ status: SvnDockStatusKind) -> Int {
        switch status {
        case .conflicted: 0
        case .obstructed: 1
        case .modified: 2
        case .added: 3
        case .deleted, .missing: 4
        case .replaced: 5
        case .unversioned: 6
        case .external: 7
        case .ignored: 8
        case .clean: 9
        }
    }
}

enum SvnDockStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case changed
    case conflicts
    case unversioned

    var id: Self { self }

    var displayName: String {
        switch self {
        case .all: "全部"
        case .changed: "变更"
        case .conflicts: "冲突"
        case .unversioned: "未纳管"
        }
    }

    func includes(_ entry: SvnDockStatusEntry) -> Bool {
        switch self {
        case .all:
            true
        case .changed:
            entry.status.isChange
        case .conflicts:
            entry.status == .conflicted || entry.repositoryStatus == .conflicted
        case .unversioned:
            entry.status == .unversioned
        }
    }
}

enum SvnDockInspectorTab: String, CaseIterable, Identifiable {
    case diff
    case history
    case information

    var id: Self { self }

    var displayName: String {
        switch self {
        case .diff: "差异"
        case .history: "历史"
        case .information: "信息"
        }
    }
}

enum SvnDockOperationKind: Hashable, Sendable {
    case loading
    case refreshing
    case updating
    case committing
    case adding
    case reverting
    case cleaning
    case resolving
    case ignoring

    var displayName: String {
        switch self {
        case .loading: "正在载入工作副本…"
        case .refreshing: "正在刷新状态…"
        case .updating: "正在更新…"
        case .committing: "正在提交…"
        case .adding: "正在添加…"
        case .reverting: "正在还原…"
        case .cleaning: "正在清理…"
        case .resolving: "正在解决冲突…"
        case .ignoring: "正在添加忽略规则…"
        }
    }
}

struct SvnDockOperationState: Identifiable, Hashable, Sendable {
    let id = UUID()
    var kind: SvnDockOperationKind
    var detail: String?
}

struct SvnDockUserFacingError: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}
