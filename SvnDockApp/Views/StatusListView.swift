import AppKit
import SwiftUI

struct StatusListView: View {
    @ObservedObject var store: SvnDockStore
    @State private var statusCounts: [SvnDockStatusFilter: Int] = [:]

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader(counts: statusCounts)
            filterBar(counts: statusCounts)

            if store.missingEntryCount > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(store.missingEntryCount) 个项目在本地缺失", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    HStack {
                        Button("清理未提交的添加记录…") {
                            store.requestMissingAdditionCleanup(allMissing: true)
                        }
                        .disabled(store.isInteractionBlocked)
                        if store.groupedMissingCount > 0 {
                            Spacer()
                            Button(store.showsMissingDetails ? "合并目录" : "显示明细") {
                                store.showsMissingDetails.toggle()
                            }
                        }
                    }
                    Text("仅清理已删除且尚未提交的新增项目，已纳管项目不会被清理。")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.orange.opacity(0.18), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

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
                            Button {
                                store.showMoreStatusEntries()
                            } label: {
                                Text("再显示 \(store.nextVisibleEntryCount) 项")
                                    .padding(.horizontal, 10)
                                    .frame(minHeight: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(SvnDockPlainButtonStyle())
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .disabled(store.isInteractionBlocked)
            }

            statusFooter
        }
        .background(SvnDockTheme.surface)
        .onReceive(store.$displayedEntries) { _ in
            // Recount when the status presentation changes, never on each
            // selection or diff-preview update in a large working copy.
            statusCounts = makeStatusCounts()
        }
    }

    private func makeStatusCounts() -> [SvnDockStatusFilter: Int] {
        var counts = Dictionary(uniqueKeysWithValues: SvnDockStatusFilter.allCases.map { ($0, 0) })
        for entry in store.entries {
            for filter in SvnDockStatusFilter.allCases where filter.includes(entry) {
                counts[filter, default: 0] += 1
            }
        }
        return counts
    }

    private func workspaceHeader(counts: [SvnDockStatusFilter: Int]) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(store.statusFilter == .conflicts ? "冲突文件" : "工作区")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(SvnDockTheme.text)
                Text(workspaceSummary(counts: counts))
                    .font(.system(size: 12))
                    .foregroundStyle(SvnDockTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                Task { await store.reloadSelectedWorkingCopy() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(SvnDockButtonStyle())
            .disabled(store.selectedWorkingCopy == nil || store.isInteractionBlocked)
            .help("刷新状态")
            .accessibilityLabel("刷新工作区状态")
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 17)
    }

    private func workspaceSummary(counts: [SvnDockStatusFilter: Int]) -> String {
        guard store.selectedWorkingCopy != nil else { return "选择工作副本以查看文件状态" }
        if store.isBusy && store.entries.isEmpty { return "正在读取文件状态…" }
        switch store.statusFilter {
        case .conflicts:
            return "发现 \(counts[.conflicts, default: 0]) 个项目存在冲突"
        case .unversioned:
            return "发现 \(counts[.unversioned, default: 0]) 个未纳管项目"
        case .all, .changed:
            let changed = counts[.changed, default: 0]
            if changed == 0 && counts[.unversioned, default: 0] > 0 {
                return "发现 \(counts[.unversioned, default: 0]) 个未纳管项目"
            }
            return changed == 0 ? "工作副本没有待提交的变更" : "发现 \(changed) 个项目发生变更"
        }
    }

    private func filterBar(counts: [SvnDockStatusFilter: Int]) -> some View {
        HStack(spacing: 5) {
            ForEach(SvnDockStatusFilter.allCases) { filter in
                let isSelected = store.statusFilter == filter
                let count = counts[filter, default: 0]
                Button {
                    store.statusFilter = filter
                } label: {
                    HStack(spacing: 4) {
                        Text(filter.displayName)
                            .fontWeight(isSelected ? .semibold : .medium)
                        Text(count.formatted())
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                isSelected ? Color.white.opacity(0.22) : SvnDockTheme.secondaryText.opacity(0.09),
                                in: Capsule()
                            )
                    }
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(isSelected ? SvnDockTheme.onAccent : SvnDockTheme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 6)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                    .background(
                        isSelected ? SvnDockTheme.accent : SvnDockTheme.subtleSurface,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? SvnDockTheme.accent.opacity(0.5) : Color.clear, lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
                .buttonStyle(SvnDockPlainButtonStyle())
                .accessibilityLabel("\(filter.displayName)，\(count) 项")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .help("\(filter.displayName)：\(count) 项")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var statusFooter: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("\(store.filteredEntryCount) 项")
                if store.hasMoreFilteredEntries {
                    Text("已显示 \(store.displayedEntries.count) 项")
                }
                if store.isFilteringStatusEntries {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer(minLength: 4)
                if !store.selectedEntryIDs.isEmpty {
                    Text("已选择 \(store.selectedEntryIDs.count) 项")
                        .foregroundStyle(SvnDockTheme.accent)
                }
            }
            if store.hasMoreFilteredEntries {
                HStack {
                    Button {
                        store.selectAllFilteredStatusEntries()
                    } label: {
                        Text("选择全部 \(store.filteredEntryCount) 项")
                            .padding(.horizontal, 8)
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SvnDockPlainButtonStyle())
                    .disabled(store.isInteractionBlocked || store.isFilteringStatusEntries)
                    Spacer()
                }
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(SvnDockTheme.secondaryText)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(SvnDockTheme.subtleSurface.opacity(0.6))
        .overlay(alignment: .top) {
            Rectangle().fill(SvnDockTheme.border).frame(height: 1)
                .allowsHitTesting(false)
        }
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
                .svnDockCardSelection()
                .tag(entry.id)
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 8, trailing: 12))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
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
                Button {
                    store.retryDirectoryLoad(for: parent)
                } label: {
                    Text("重试")
                        .padding(.horizontal, 8)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SvnDockPlainButtonStyle())
            }
        case let .more(parent, count):
            directoryMessage(depth: row.depth) {
                Button {
                    store.showMoreDirectoryChildren(for: parent)
                } label: {
                    Text("再显示 \(count) 项")
                        .padding(.horizontal, 8)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SvnDockPlainButtonStyle())
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
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
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
        HStack(spacing: 4) {
            expansionControl
            StatusEntryRow(entry: entry)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(
            store.selectedEntryIDs.contains(entry.id) ? SvnDockTheme.selection : SvnDockTheme.surface,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    store.selectedEntryIDs.contains(entry.id)
                        ? SvnDockTheme.accent.opacity(0.2) : SvnDockTheme.border,
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
        .padding(.leading, CGFloat(depth) * 16)
        .contentShape(RoundedRectangle(cornerRadius: 10))
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
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SvnDockPlainButtonStyle())
            .help(store.isDirectoryExpanded(entry) ? "收起目录" : "展开目录")
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
            if entry.nodeKind == .file && entry.status != .missing {
                Button("在窗口中查看差异") {
                    openDiffWindow()
                }
            }
            if entry.status == .missing {
                Button("清理缺失的添加记录…") {
                    store.selectedEntryIDs = [entry.id]
                    store.requestMissingAdditionCleanup(for: entry)
                }
                Button("还原已纳管文件…", role: .destructive) {
                    store.selectedEntryIDs = [entry.id]
                    store.requestRevertConfirmation()
                }
            } else if entry.status == .added {
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
              entry.status != .missing,
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
            SvnDockFileIcon(entry: entry, size: 38)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.fileName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SvnDockTheme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SvnDockStatusPill(status: entry.status)
                        .fixedSize()
                }
                HStack(spacing: 6) {
                    Text(entry.parentPath.isEmpty ? "/" : entry.parentPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let changelist = entry.changelist {
                        Text(changelist)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(SvnDockTheme.secondaryText.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    }
                    if let repositoryStatus = entry.repositoryStatus, repositoryStatus != .clean {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(repositoryStatus.tint)
                            .help("仓库端：\(repositoryStatus.displayName)")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(SvnDockTheme.secondaryText)
                if entry.missingDescendantCount > 0 {
                    Text("含 \(entry.missingDescendantCount) 个缺失子项")
                        .font(.system(size: 10))
                        .foregroundStyle(SvnDockTheme.secondaryText)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.relativePath)，\(entry.status.displayName)")
    }
}
