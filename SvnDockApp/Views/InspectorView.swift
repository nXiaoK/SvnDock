import AppKit
import SwiftUI

struct InspectorView: View {
    @ObservedObject var store: SvnDockStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(SvnDockInspectorTab.allCases) { tab in
                    Button {
                        store.inspectorTab = tab
                    } label: {
                        Label(tab.displayName, systemImage: tabSymbol(tab))
                            .font(.system(size: 14, weight: store.inspectorTab == tab ? .semibold : .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                            .foregroundStyle(store.inspectorTab == tab ? SvnDockTheme.accent : SvnDockTheme.secondaryText)
                            .background {
                                if store.inspectorTab == tab {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(SvnDockTheme.surface)
                                        .shadow(color: SvnDockTheme.accent.opacity(0.10), radius: 3, y: 1)
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(SvnDockTheme.accent.opacity(0.25), lineWidth: 1)
                                                .allowsHitTesting(false)
                                        }
                                }
                            }
                    }
                    .buttonStyle(SvnDockPlainButtonStyle())
                    .accessibilityAddTraits(store.inspectorTab == tab ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(SvnDockTheme.subtleSurface)

            Divider()

            inspectorContent
        }
        .background(SvnDockTheme.surface)
        .task(id: diffTaskID) {
            guard store.inspectorTab == .diff else { return }
            await store.loadDiffForSelection()
        }
        .task(id: historyTaskID) {
            guard store.inspectorTab == .history else { return }
            await store.ensureHistoryForSelection()
        }
    }

    private func tabSymbol(_ tab: SvnDockInspectorTab) -> String {
        switch tab {
        case .diff: "doc.text"
        case .history: "clock"
        case .information: "info.circle"
        }
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch store.inspectorTab {
        case .history:
            HistoryInspectorView(store: store)
        case .diff, .information:
            fileInspectorContent
        }
    }

    @ViewBuilder
    private var fileInspectorContent: some View {
        if store.selectedEntryIDs.count > 1 {
            SvnDockEmptyState(
                symbol: "square.stack.3d.up",
                title: "已选择多个项目",
                message: "选择单个文件以查看差异和详细信息。"
            )
        } else if let entry = store.primarySelectedEntry {
            if store.inspectorTab == .diff {
                DiffInspector(store: store, entry: entry)
                    .id(entry.id)
            } else {
                InformationInspector(store: store, entry: entry)
            }
        } else {
            SvnDockEmptyState(
                symbol: "doc.text.magnifyingglass",
                title: "检查文件",
                message: "选择一个文件以查看本地差异或 SVN 信息。"
            )
        }
    }

    private var diffTaskID: String {
        "\(store.inspectorTab.rawValue)::\(store.selectedWorkingCopyID?.uuidString ?? "none")::\(store.selectedEntryIDs.count)::\(store.primarySelectedEntry?.id ?? "none")"
    }

    private var historyTaskID: String {
        let workingCopyID = store.selectedWorkingCopyID?.uuidString ?? "none"
        let entryID = store.primarySelectedEntry?.id ?? "none"
        return "\(store.inspectorTab.rawValue)::\(workingCopyID)::\(store.selectedEntryIDs.count)::\(entryID)"
    }
}

private struct DiffInspector: View {
    @ObservedObject var store: SvnDockStore
    let entry: SvnDockStatusEntry
    @StateObject private var presentationModel = DiffPresentationModel()

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    inspectorHeader
                    Divider()
                    if entry.status == .conflicted {
                        conflictBanner
                        Divider()
                    }
                    diffContent
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if geometry.size.width >= 820 {
                    Divider()
                    FileDetailsSidebar(store: store, entry: entry,
                                       statistics: store.isLoadingDiff ? nil : presentationModel.statistics)
                        .frame(width: 208)
                }
            }
        }
    }

    @ViewBuilder
    private var diffContent: some View {
        if store.isLoadingDiff {
            ProgressView("正在读取差异…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entry.status == .missing {
            VStack(spacing: 12) {
                SvnDockEmptyState(
                    symbol: "exclamationmark.triangle",
                    title: "项目在本地已不存在",
                    message: "添加后尚未提交就删除的项目，可以清理其添加记录。目录会连同缺失子项一起处理。已纳管文件请恢复文件或明确标记为 SVN 删除。"
                )
                Button("清理缺失的添加记录…") {
                    store.requestMissingAdditionCleanup(for: entry)
                }
                .buttonStyle(SvnDockButtonStyle())
                .disabled(store.isInteractionBlocked)
                .padding(.bottom, 24)
            }
        } else if entry.nodeKind == .directory {
            SvnDockEmptyState(
                symbol: "folder",
                title: "目录没有文本差异",
                message: "可在信息标签中查看目录状态。"
            )
        } else if entry.status == .unversioned {
            SvnDockEmptyState(
                symbol: "questionmark.circle",
                title: "文件尚未纳管",
                message: "先将文件添加到 SVN，随后即可查看版本差异。"
            )
        } else if store.diffText.isEmpty {
            SvnDockEmptyState(
                symbol: "doc.text",
                title: "没有文本差异",
                message: "该文件可能是二进制文件，或内容与基础版本一致。"
            )
        } else {
            DiffContentView(text: store.diffText, presentationModel: presentationModel)
                .id(entry.id)
        }
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                SvnDockFileIcon(entry: entry, size: 46)
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.fileName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SvnDockTheme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(entry.parentPath.isEmpty ? "工作副本根目录" : entry.parentPath)
                        .font(.system(size: 12))
                        .foregroundStyle(SvnDockTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                SvnDockStatusPill(status: entry.status)
            }
            ViewThatFits(in: .horizontal) {
                metadata(showsDate: true)
                metadata(showsDate: false)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
    }

    private func metadata(showsDate: Bool) -> some View {
        HStack(spacing: 16) {
            Label {
                if let revision = store.selectedWorkingCopy?.revision {
                    Text("工作副本 r\(String(revision))")
                } else {
                    Text("BASE → 工作副本")
                }
            } icon: {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(SvnDockTheme.accent)
            }
            .fixedSize()
            if showsDate, let modifiedAt = entry.modifiedAt {
                Label(modifiedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    .lineLimit(1)
                    .help("文件修改时间")
            }
            Spacer(minLength: 4)
            Button {
                Task { await store.loadDiffForSelection() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SvnDockPlainButtonStyle())
            .disabled(store.isLoadingDiff)
            .help("重新载入差异")
            .accessibilityLabel("重新载入差异")
        }
        .font(.system(size: 12))
        .foregroundStyle(SvnDockTheme.secondaryText)
    }

    private var conflictBanner: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(SvnDockTheme.red)
                Text("此文件存在冲突")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("解决冲突…") {
                    store.requestResolveConfirmation(for: entry)
                }
                .buttonStyle(SvnDockButtonStyle(primary: true))
                .disabled(store.isInteractionBlocked)
            }
            Text(entry.nodeKind == .file && entry.conflictKinds == [.text]
                 ? "检查文件内容后，可选择保留工作副本、接受本地或服务器版本。"
                 : "请先检查并处理文件或目录，再将冲突标记为已解决。")
                .font(.system(size: 12))
                .foregroundStyle(SvnDockTheme.secondaryText)
        }
        .padding(16)
        .background(SvnDockTheme.red.opacity(0.05))
    }
}

private struct FileDetailsSidebar: View {
    @ObservedObject var store: SvnDockStore
    let entry: SvnDockStatusEntry
    let statistics: DiffStatistics?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let statistics, statistics.hunks > 0 {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("变更概览")
                            .font(.system(size: 13, weight: .semibold))
                        HStack(spacing: 20) {
                            Text("+\(statistics.additions)").foregroundStyle(SvnDockTheme.green)
                            Text("−\(statistics.deletions)").foregroundStyle(SvnDockTheme.red)
                        }
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                        Text("\(statistics.hunks) 处变更 · \(statistics.additions + statistics.deletions) 行修改")
                            .font(.system(size: 11))
                            .foregroundStyle(SvnDockTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(SvnDockTheme.subtleSurface, in: RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 4) {
                    sidebarAction("复制文件路径", symbol: "doc.on.doc", action: copyPath)
                    sidebarAction("在 Finder 中显示", symbol: "folder", action: reveal)
                    sidebarAction("查看文件历史", symbol: "clock") { store.inspectorTab = .history }
                    if canOpenDiff {
                        sidebarAction("在独立窗口查看", symbol: "arrow.up.forward.app") {
                            openWindow(value: SvnDockDiffRequest(
                                workingCopyID: entry.workingCopyID, relativePath: entry.relativePath
                            ))
                        }
                    }
                }
                .padding(.horizontal, 6)
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    Text("文件信息")
                        .font(.system(size: 13, weight: .semibold))
                    InformationRow(title: "文件名", value: entry.fileName)
                    InformationRow(title: "路径", value: entry.parentPath.isEmpty ? "." : entry.parentPath)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("状态")
                            .font(.caption)
                            .foregroundStyle(SvnDockTheme.secondaryText)
                        SvnDockStatusPill(status: entry.status)
                    }
                    if let revision = store.selectedWorkingCopy?.revision {
                        InformationRow(title: "工作副本版本", value: "r\(revision)")
                    }
                    if let fileSize = entry.fileSize {
                        InformationRow(title: "文件大小", value: ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
                    }
                    if let modifiedAt = entry.modifiedAt {
                        InformationRow(title: "修改时间", value: modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .padding(.horizontal, 6)
            }
            .padding(14)
        }
        .foregroundStyle(SvnDockTheme.text)
        .background(SvnDockTheme.surface)
    }

    private var canOpenDiff: Bool {
        entry.nodeKind == .file && ![.unversioned, .ignored, .missing, .external].contains(entry.status)
    }

    private func sidebarAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12))
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(SvnDockPlainButtonStyle())
    }

    private func reveal() {
        guard let root = store.selectedWorkingCopy?.rootURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root.appending(path: entry.relativePath)])
    }

    private func copyPath() {
        guard let root = store.selectedWorkingCopy?.rootURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(root.appending(path: entry.relativePath).path(percentEncoded: false), forType: .string)
    }
}


private struct InformationInspector: View {
    @ObservedObject var store: SvnDockStore
    let entry: SvnDockStatusEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    SvnDockFileIcon(entry: entry, size: 50)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(entry.fileName)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(SvnDockTheme.text)
                        SvnDockStatusPill(status: entry.status)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 18) {
                    InformationRow(title: "相对路径", value: entry.relativePath)
                    if let root = store.selectedWorkingCopy?.rootURL {
                        InformationRow(
                            title: "完整路径",
                            value: root.appending(path: entry.relativePath).path(percentEncoded: false)
                        )
                    }
                    InformationRow(title: "节点类型", value: entry.nodeKind == .directory ? "目录" : "文件")
                    InformationRow(title: "本地状态", value: entry.status.displayName)
                    if let repositoryStatus = entry.repositoryStatus {
                        InformationRow(title: "仓库状态", value: repositoryStatus.displayName)
                    }
                    if let changelist = entry.changelist {
                        InformationRow(title: "变更列表", value: changelist)
                    }
                    if let lockOwner = entry.lockOwner {
                        InformationRow(title: "锁定者", value: lockOwner)
                    }
                    if let fileSize = entry.fileSize {
                        InformationRow(title: "大小", value: ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
                    }
                    if let modifiedAt = entry.modifiedAt {
                        InformationRow(title: "修改时间", value: modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(SvnDockTheme.subtleSurface, in: RoundedRectangle(cornerRadius: 12))

                Divider()

                HStack {
                    Button {
                        reveal()
                    } label: {
                        Label("在 Finder 中显示", systemImage: "folder")
                    }
                    Button {
                        copyPath()
                    } label: {
                        Label("复制路径", systemImage: "doc.on.doc")
                    }
                }
                .buttonStyle(SvnDockButtonStyle())
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func reveal() {
        guard let root = store.selectedWorkingCopy?.rootURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root.appending(path: entry.relativePath)])
    }

    private func copyPath() {
        guard let root = store.selectedWorkingCopy?.rootURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            root.appending(path: entry.relativePath).path(percentEncoded: false),
            forType: .string
        )
    }
}

private struct InformationRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(SvnDockTheme.secondaryText)
            Text(value)
                .font(.callout)
                .foregroundStyle(SvnDockTheme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
