import Foundation

/// A server check is a separate snapshot: incoming-only paths must never be
/// filtered through, or counted as changes in, the local status list.
struct SvnDockRemoteStatusEntry: Identifiable, Hashable, Sendable {
    let relativePath: String
    let status: SvnDockStatusKind
    let propertiesChanged: Bool

    init(relativePath: String, status: SvnDockStatusKind, propertiesChanged: Bool = false) {
        self.relativePath = relativePath
        self.status = status
        self.propertiesChanged = propertiesChanged
    }

    var id: String { relativePath }

    var displayName: String {
        relativePath == "." ? "工作副本根目录" : relativePath
    }

    var changeDescription: String {
        if status == .clean {
            return propertiesChanged ? "属性更新" : "内容更新"
        }
        return propertiesChanged ? "\(status.displayName) · 属性更新" : status.displayName
    }
}

struct SvnDockRemoteStatusSnapshot: Hashable, Sendable {
    let entries: [SvnDockRemoteStatusEntry]
    let checkedAt: Date

    init(entries: [SvnDockRemoteStatusEntry], checkedAt: Date = Date()) {
        self.entries = entries.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        self.checkedAt = checkedAt
    }
}

struct SvnDockRemoteStatusState: Hashable, Sendable {
    var snapshot: SvnDockRemoteStatusSnapshot?
    var isChecking = false
    var lastError: String?
    var isStale = false

    var summary: String {
        if isChecking { return "服务器：正在检查…" }
        if lastError != nil {
            return snapshot == nil ? "服务器：检查失败" : "服务器：检查失败 · 旧结果"
        }
        guard let snapshot else { return "服务器：未检查" }
        if isStale { return "服务器：结果待刷新" }
        return snapshot.entries.isEmpty
            ? "服务器：未发现更新"
            : "服务器：\(snapshot.entries.count) 项更新"
    }

    var showsPreviousResult: Bool {
        snapshot != nil && (isStale || lastError != nil || isChecking)
    }
}

extension SvnDockWorkingCopy {
    var localStatusSummary: String {
        guard lastRefreshedAt != nil else { return "本地：尚未刷新" }
        if counts.conflicts > 0 { return "本地：\(counts.conflicts) 项冲突" }
        if counts.changed > 0 { return "本地：\(counts.changed) 项变更" }
        if counts.unversioned > 0 { return "本地：\(counts.unversioned) 项未纳管" }
        return "本地：无修改"
    }

    var localStatusDetail: String {
        guard let lastRefreshedAt else { return "刷新本地状态后可查看修改与冲突。" }
        return "\(counts.changed) 项变更，\(counts.conflicts) 项冲突，\(counts.unversioned) 项未纳管\n本地刷新：\(lastRefreshedAt.formatted(date: .abbreviated, time: .standard))"
    }
}
