import AppKit
import SwiftUI

struct StatusListView: View {
    @ObservedObject var store: SvnDockStore

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()

            if store.selectedWorkingCopy == nil {
                SvnDockEmptyState(
                    symbol: "sidebar.left",
                    title: "选择工作副本",
                    message: "从左侧选择一个工作副本以查看本地状态。"
                )
            } else if store.entries.isEmpty && !store.isBusy {
                SvnDockEmptyState(
                    symbol: "checkmark.circle",
                    title: "工作副本是干净的",
                    message: "没有检测到待提交、本地新增或冲突文件。"
                )
            } else if store.displayedEntries.isEmpty && !store.isBusy {
                SvnDockEmptyState(
                    symbol: "line.3.horizontal.decrease.circle",
                    title: "没有匹配项目",
                    message: "调整筛选条件或搜索文字后重试。"
                )
            } else {
                List(selection: $store.selectedEntryIDs) {
                    ForEach(statusTreeRows) { row in
                        statusTreeRow(row)
                    }

                    if store.hasMoreFilteredEntries {
                        HStack {
                            Spacer()
                            Button("再显示 \(store.nextVisibleEntryCount) 项") {
                                store.showMoreStatusEntries()
                            }
                            .buttonStyle(.borderless)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                }
                .listStyle(.inset)
                .disabled(store.isInteractionBlocked)
            }

            Divider()
            statusFooter
        }
        .navigationTitle(store.selectedWorkingCopy?.name ?? "状态")
        .searchable(text: $store.searchQuery, placement: .toolbar, prompt: "筛选路径")
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("状态", selection: $store.statusFilter) {
                ForEach(SvnDockStatusFilter.allCases) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Button {
                Task { await store.reloadSelectedWorkingCopy() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(store.selectedWorkingCopy == nil || store.isInteractionBlocked)
            .help("刷新状态")
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    @ViewBuilder
    private var statusFooter: some View {
        HStack(spacing: 12) {
            Text("\(store.filteredEntryCount) 项")
            if store.hasMoreFilteredEntries {
                Text("已显示 \(store.displayedEntries.count) 项")
                Button("选择全部 \(store.filteredEntryCount) 项") {
                    store.selectAllFilteredStatusEntries()
                }
                .buttonStyle(.borderless)
                .disabled(store.isInteractionBlocked || store.isFilteringStatusEntries)
            }
            if store.isFilteringStatusEntries {
                ProgressView()
                    .controlSize(.small)
            }
            if !store.selectedEntryIDs.isEmpty {
                Text("已选择 \(store.selectedEntryIDs.count) 项")
            }
            Spacer()
            if let refreshedAt = store.selectedWorkingCopy?.lastRefreshedAt {
                Text("刷新于 \(refreshedAt.formatted(date: .omitted, time: .shortened))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private var statusTreeRows: [StatusTreeRow] {
        var rows: [StatusTreeRow] = []
        var nestedEntryIDs = Set<SvnDockStatusEntry.ID>()
        for entry in store.displayedEntries {
            collectNestedEntryIDs(for: entry, into: &nestedEntryIDs)
        }

        var appendedEntryIDs = Set<SvnDockStatusEntry.ID>()
        for entry in store.displayedEntries where !nestedEntryIDs.contains(entry.id) {
            appendStatusTreeRows(
                for: entry,
                depth: 0,
                appendedEntryIDs: &appendedEntryIDs,
                to: &rows
            )
        }
        return rows
    }

    private func collectNestedEntryIDs(
        for entry: SvnDockStatusEntry,
        into nestedEntryIDs: inout Set<SvnDockStatusEntry.ID>
    ) {
        guard store.isDirectoryExpanded(entry) else { return }
        for child in store.visibleDirectoryChildren(for: entry) {
            nestedEntryIDs.insert(child.id)
            collectNestedEntryIDs(for: child, into: &nestedEntryIDs)
        }
    }

    private func appendStatusTreeRows(
        for entry: SvnDockStatusEntry,
        depth: Int,
        appendedEntryIDs: inout Set<SvnDockStatusEntry.ID>,
        to rows: inout [StatusTreeRow]
    ) {
        guard appendedEntryIDs.insert(entry.id).inserted else { return }
        rows.append(.entry(entry, depth: depth))
        guard store.isDirectoryExpanded(entry) else { return }

        for child in store.visibleDirectoryChildren(for: entry) {
            appendStatusTreeRows(
                for: child,
                depth: depth + 1,
                appendedEntryIDs: &appendedEntryIDs,
                to: &rows
            )
        }

        if store.isLoadingDirectory(entry) {
            rows.append(.loading(parent: entry, depth: depth + 1))
        } else if let message = store.directoryError(for: entry) {
            rows.append(.error(parent: entry, message: message, depth: depth + 1))
        } else if store.hasMoreDirectoryChildren(for: entry) {
            rows.append(.more(
                parent: entry,
                count: store.remainingDirectoryChildCount(for: entry),
                depth: depth + 1
            ))
        }
    }

    @ViewBuilder
    private func statusTreeRow(_ row: StatusTreeRow) -> some View {
        switch row.kind {
        case let .entry(entry):
            StatusTreeEntryRowView(store: store, entry: entry, depth: row.depth)
                .tag(entry.id)
        case .loading:
            directoryMessage(depth: row.depth) {
                ProgressView()
                    .controlSize(.small)
                Text("正在读取目录…")
            }
        case let .error(parent, message):
            directoryMessage(depth: row.depth) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .lineLimit(2)
                Button("重试") {
                    store.retryDirectoryLoad(for: parent)
                }
                .buttonStyle(.borderless)
            }
        case let .more(parent, count):
            directoryMessage(depth: row.depth) {
                Button("再显示 \(count) 项") {
                    store.showMoreDirectoryChildren(for: parent)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func directoryMessage<Content: View>(
        depth: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8, content: content)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, CGFloat(depth) * 18 + 18)
            .padding(.vertical, 5)
    }

}

private struct StatusTreeRow: Identifiable {
    enum Kind {
        case entry(SvnDockStatusEntry)
        case loading(parent: SvnDockStatusEntry)
        case error(parent: SvnDockStatusEntry, message: String)
        case more(parent: SvnDockStatusEntry, count: Int)
    }

    let id: String
    let depth: Int
    let kind: Kind

    static func entry(_ entry: SvnDockStatusEntry, depth: Int) -> Self {
        Self(id: entry.id, depth: depth, kind: .entry(entry))
    }

    static func loading(parent: SvnDockStatusEntry, depth: Int) -> Self {
        Self(id: "directory-loading::\(parent.id)", depth: depth, kind: .loading(parent: parent))
    }

    static func error(
        parent: SvnDockStatusEntry,
        message: String,
        depth: Int
    ) -> Self {
        Self(
            id: "directory-error::\(parent.id)",
            depth: depth,
            kind: .error(parent: parent, message: message)
        )
    }

    static func more(parent: SvnDockStatusEntry, count: Int, depth: Int) -> Self {
        Self(
            id: "directory-more::\(parent.id)",
            depth: depth,
            kind: .more(parent: parent, count: count)
        )
    }
}

private struct StatusTreeEntryRowView: View {
    @ObservedObject var store: SvnDockStore
    let entry: SvnDockStatusEntry
    let depth: Int

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 2) {
            expansionControl
            StatusEntryRow(entry: entry)
        }
        .padding(.leading, CGFloat(depth) * 18)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                if store.canExpandDirectory(entry) {
                    store.toggleDirectoryExpansion(for: entry)
                } else {
                    openDiffWindow()
                }
            }
        )
        .contextMenu { entryContextMenu }
    }

    @ViewBuilder
    private var expansionControl: some View {
        if store.canExpandDirectory(entry) {
            Button {
                store.toggleDirectoryExpansion(for: entry)
            } label: {
                Image(systemName: store.isDirectoryExpanded(entry)
                    ? "chevron.down"
                    : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .frame(width: 16, height: 20)
            }
            .buttonStyle(.plain)
            .help(store.isDirectoryExpanded(entry) ? "收起目录" : "展开目录")
        } else {
            Color.clear.frame(width: 16, height: 20)
        }
    }

    @ViewBuilder
    private var entryContextMenu: some View {
        if entry.status == .unversioned
            || (entry.status == .added && entry.nodeKind == .directory) {
            Button(entry.status == .added ? "添加目录内容到 SVN" : "添加到 SVN") {
                store.selectedEntryIDs = [entry.id]
                Task { await store.addSelectedEntries() }
            }
        }

        if entry.status == .unversioned {
            Menu("忽略") {
                Button("忽略此名称") {
                    store.selectedEntryIDs = [entry.id]
                    store.requestIgnoreConfirmation(for: entry, mode: .name)
                }
                if entry.nodeKind == .file,
                   !(entry.relativePath as NSString).pathExtension.isEmpty {
                    Button("忽略所有 .\((entry.relativePath as NSString).pathExtension) 文件") {
                        store.selectedEntryIDs = [entry.id]
                        store.requestIgnoreConfirmation(for: entry, mode: .fileExtension)
                    }
                }
            }
        }

        if entry.status.isChange {
            if entry.nodeKind == .file {
                Button("在窗口中查看差异") {
                    openDiffWindow()
                }
            }
            if entry.status == .added {
                Button("取消添加…") {
                    store.selectedEntryIDs = [entry.id]
                    store.requestUnscheduleAddConfirmation(for: entry)
                }
            } else {
                Button("还原…", role: .destructive) {
                    store.selectedEntryIDs = [entry.id]
                    store.requestRevertConfirmation()
                }
            }
        }

        if entry.status == .conflicted {
            Button("解决冲突…") {
                store.selectedEntryIDs = [entry.id]
                store.requestResolveConfirmation(for: entry)
            }
        }

        if entry.status != .unversioned && entry.status != .ignored {
            Button("查看提交历史…") {
                store.selectedEntryIDs = [entry.id]
                Task { await store.showHistoryForSelection() }
            }
        }

        Divider()

        Button("在 Finder 中显示") {
            reveal()
        }
        Button("复制相对路径") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.relativePath, forType: .string)
        }
    }

    private func reveal() {
        guard let root = store.selectedWorkingCopy?.rootURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([
            root.appending(path: entry.relativePath)
        ])
    }

    private func openDiffWindow() {
        guard entry.nodeKind == .file,
              entry.status != .unversioned,
              entry.status != .ignored,
              entry.status != .external else { return }
        store.selectedEntryIDs = [entry.id]
        openWindow(value: SvnDockDiffRequest(
            workingCopyID: entry.workingCopyID,
            relativePath: entry.relativePath
        ))
    }
}

private struct StatusEntryRow: View {
    let entry: SvnDockStatusEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.status.symbolName)
                .foregroundStyle(entry.status.tint)
                .frame(width: 18)

            Image(systemName: entry.nodeKind == .directory ? "folder.fill" : "doc.fill")
                .foregroundStyle(entry.nodeKind == .directory ? .blue : .secondary)
                .frame(width: 17)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.fileName)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(entry.status.displayName)
                        .foregroundStyle(entry.status.tint)
                    if !entry.parentPath.isEmpty {
                        Text(entry.parentPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let changelist = entry.changelist {
                        Text(changelist)
                            .padding(.horizontal, 4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            if let repositoryStatus = entry.repositoryStatus, repositoryStatus != .clean {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(repositoryStatus.tint)
                    .help("仓库端：\(repositoryStatus.displayName)")
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.relativePath)，\(entry.status.displayName)")
    }
}
