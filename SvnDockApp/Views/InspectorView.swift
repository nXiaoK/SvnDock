import AppKit
import SwiftUI

struct InspectorView: View {
    @ObservedObject var store: SvnDockStore

    var body: some View {
        VStack(spacing: 0) {
            Picker("检查器", selection: $store.inspectorTab) {
                ForEach(SvnDockInspectorTab.allCases) { tab in
                    Text(tab.displayName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            inspectorContent
        }
        .navigationTitle("检查器")
        .task(id: diffTaskID) {
            guard store.inspectorTab == .diff else { return }
            await store.loadDiffForSelection()
        }
        .task(id: historyTaskID) {
            guard store.inspectorTab == .history else { return }
            await store.ensureHistoryForSelection()
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
        "\(store.inspectorTab.rawValue)::\(store.primarySelectedEntry?.id ?? "none")"
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

    var body: some View {
        VStack(spacing: 0) {
            inspectorHeader
            Divider()

            if store.isLoadingDiff {
                ProgressView("正在读取差异…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                DiffTextView(text: store.diffText)
            }
        }
    }

    private var inspectorHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.status.symbolName)
                .foregroundStyle(entry.status.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.fileName)
                    .font(.headline)
                    .lineLimit(1)
                Text(entry.parentPath.isEmpty ? "." : entry.parentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                Task { await store.loadDiffForSelection() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(store.isLoadingDiff)
            .help("重新载入差异")
        }
        .padding(10)
    }
}

private struct DiffTextView: View {
    private let lines: [Substring]

    init(text: String) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(index + 1, format: .number)
                            .foregroundStyle(.tertiary)
                            .frame(minWidth: 34, alignment: .trailing)
                            .textSelection(.disabled)
                        Text(String(line).isEmpty ? " " : String(line))
                            .foregroundStyle(foreground(for: line))
                            .textSelection(.enabled)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(for: line))
                }
            }
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func foreground(for line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") {
            return .secondary
        }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        return .primary
    }

    private func background(for line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") {
            return Color.secondary.opacity(0.08)
        }
        if line.hasPrefix("+") { return Color.green.opacity(0.10) }
        if line.hasPrefix("-") { return Color.red.opacity(0.10) }
        return .clear
    }
}

private struct InformationInspector: View {
    @ObservedObject var store: SvnDockStore
    let entry: SvnDockStatusEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: entry.nodeKind == .directory ? "folder.fill" : "doc.fill")
                        .font(.title2)
                        .foregroundStyle(entry.nodeKind == .directory ? Color.blue : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.fileName)
                            .font(.headline)
                        SvnDockStatusLabel(status: entry.status)
                            .font(.caption)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 11) {
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

                Divider()

                HStack {
                    Button("在 Finder 中显示") {
                        reveal()
                    }
                    Button("复制路径") {
                        copyPath()
                    }
                }
            }
            .padding(16)
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
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
