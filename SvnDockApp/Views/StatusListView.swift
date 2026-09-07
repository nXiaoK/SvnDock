import AppKit
import SwiftUI

struct StatusListView: View {
    @ObservedObject var store: SvnDockStore

    @Environment(\.openWindow) private var openWindow
    @State private var collapsedPaths = Set<String>()
    @State private var compactDirectories = true

    private var statusCounts: [SvnDockStatusFilter: Int] {
        let counts = store.statusCounts
        return [.all: store.entries.count, .changed: counts.changed,
                .conflicts: counts.conflicts, .unversioned: counts.unversioned,
                .ignored: store.ignoredEntries.count]
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader(counts: statusCounts)
            filterBar(counts: statusCounts)
            treeToolbar

            if store.statusFilter == .all, store.searchQuery.isEmpty,
               let entry = store.finderTargetOutsideChangeList {
                Button {
                    store.selectedEntryIDs = [entry.id]
                    store.inspectorTab = .diff
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Finder 中所选项目", systemImage: "cursorarrow")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        HStack {
                            Text(entry.relativePath)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            SvnDockStatusPill(status: entry.status)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(SvnDockTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(SvnDockPlainButtonStyle())
                .disabled(store.isInteractionBlocked)
                .help(entry.relativePath)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }

            if store.statusCounts.conflicts > 0 && store.statusFilter != .ignored {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(store.statusCounts.conflicts) 个项目存在冲突", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(SvnDockTheme.red)
                    HStack(spacing: 10) {
                        Button("显示冲突") { store.showConflicts() }
                        Button("审阅全部冲突…") { store.requestResolveAllConflicts() }
                    }
                    .buttonStyle(SvnDockButtonStyle())
                    .disabled(store.isInteractionBlocked)
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(SvnDockTheme.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            if store.missingEntryCount > 0 && store.statusFilter != .ignored {
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(store.missingEntryCount) 个项目在本地缺失", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    if store.missingVersionedCount > 0 {
                        Button("标记 \(store.missingVersionedCount) 个已纳管项目为删除…") {
                            store.requestMissingDeletion(allMissing: true)
                        }
                        .disabled(store.isInteractionBlocked)
                    }
                    if store.missingAdditionCount > 0 {
                        Button("清理 \(store.missingAdditionCount) 个未提交的添加记录…") {
                            store.requestMissingAdditionCleanup(allMissing: true)
                        }
                        .disabled(store.isInteractionBlocked)
                    }
                    Text("已纳管项目标记删除后需提交到仓库；未提交的新增项目可清理添加记录。")
                        .foregroundStyle(.secondary)
                    if store.missingEntryCount > store.missingVersionedCount + store.missingAdditionCount {
                        Text("部分项目状态未确认或存在冲突，请刷新后检查。")
                            .foregroundStyle(.secondary)
                    }
                    if store.groupedMissingCount > 0 {
                        HStack {
                            Spacer()
                            Button(store.showsMissingDetails ? "合并目录" : "显示明细") {
                                store.showsMissingDetails.toggle()
                            }
                        }
                    }
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

            if store.statusFilter == .ignored, store.selectedWorkingCopy != nil {
                Text("右键项目可取消忽略。忽略目录整体列出；通配规则会影响同目录的所有匹配名称。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            if store.selectedWorkingCopy == nil {
                SvnDockEmptyState(
                    symbol: "sidebar.left",
                    title: "选择工作副本",
                    message: "从左侧选择一个工作副本以查看本地状态。"
                )
            } else if let message = store.statusRecoveryMessage {
                SvnDockEmptyState(symbol: "exclamationmark.triangle", title: "本地状态待确认",
                                  message: message, actionTitle: "重新读取状态") {
                    Task { await store.reloadSelectedWorkingCopy() }
                }
            } else if store.statusFilter == .ignored, store.isLoadingIgnoredEntries {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在读取已忽略项目…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.statusFilter == .ignored, let error = store.ignoredEntriesError {
                VStack(spacing: 12) {
                    SvnDockEmptyState(symbol: "exclamationmark.triangle", title: "读取忽略项失败", message: error)
                    Button("重试") { store.retryIgnoredEntries() }
                        .buttonStyle(SvnDockButtonStyle())
                        .disabled(store.isInteractionBlocked)
                }
                .padding(.bottom, 24)
            } else if store.statusFilter == .ignored, !store.hasLoadedIgnoredEntries {
                VStack(spacing: 12) {
                    SvnDockEmptyState(symbol: "eye.slash", title: "忽略项尚未读取",
                                      message: "读取当前工作副本中匹配 SVN 忽略规则的项目。")
                    Button("读取已忽略项目") { store.loadIgnoredEntriesIfNeeded() }
                        .buttonStyle(SvnDockButtonStyle())
                        .disabled(store.isInteractionBlocked)
                }
                .padding(.bottom, 24)
            } else if store.statusFilter == .ignored, store.ignoredEntries.isEmpty, store.hasLoadedIgnoredEntries {
                SvnDockEmptyState(
                    symbol: "eye.slash", title: "没有已忽略项目",
                    message: "当前磁盘上没有匹配 SVN 忽略规则的项目。"
                )
            } else if store.statusFilter != .ignored && store.entries.isEmpty && !store.isBusy {
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
                .environment(\.defaultMinListRowHeight, 28)
                // Native primary actions preserve immediate List selection,
                // including Command/Shift clicks and keyboard navigation.
                // A row-level double-tap gesture consumes those mouse events.
                .contextMenu(forSelectionType: SvnDockStatusEntry.ID.self) { _ in
                    EmptyView()
                } primaryAction: { entryIDs in
                    guard !store.isInteractionBlocked, entryIDs.count == 1 else { return }
                    store.selectedEntryIDs = entryIDs
                    guard let entry = store.primarySelectedEntry else { return }
                    if let node = statusTreeRows.compactMap({ row -> SvnDockStatusTree.Node? in
                        if case let .node(node) = row.kind, node.entry?.id == entry.id { return node }
                        return nil
                    }).first, !node.children.isEmpty || store.canExpandDirectory(entry) {
                        toggle(node)
                    } else {
                        openDiffWindow(for: entry)
                    }
                }
                .disabled(store.isInteractionBlocked)
            }

            statusFooter
        }
        .background(SvnDockTheme.surface)
        .onChange(of: store.selectedWorkingCopyID) { collapsedPaths = [] }
        .onChange(of: store.statusFilter) { collapsedPaths = [] }
        .onChange(of: store.searchQuery) { collapsedPaths = [] }
        .onChange(of: store.selectedEntryIDs) {
            // Finder and keyboard selection should reveal a hidden descendant.
            for entry in store.selectedEntries {
                collapsedPaths = collapsedPaths.filter {
                    entry.relativePath != $0 && !entry.relativePath.hasPrefix($0 + "/")
                }
            }
        }
    }

    private func workspaceHeader(counts: [SvnDockStatusFilter: Int]) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(store.statusFilter == .conflicts ? "冲突项目" : store.statusFilter == .ignored ? "已忽略项目" : "工作区")
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
        case .ignored:
            if store.isLoadingIgnoredEntries { return "正在读取 SVN 忽略项…" }
            if store.ignoredEntriesError != nil { return "读取失败，请重试" }
            return store.hasLoadedIgnoredEntries ? "发现 \(counts[.ignored, default: 0]) 个已忽略项目" : "按需读取已忽略项目"
        case .all, .changed:
            let changed = counts[.changed, default: 0]
            if changed == 0 && counts[.unversioned, default: 0] > 0 {
                return "发现 \(counts[.unversioned, default: 0]) 个未纳管项目"
            }
            return changed == 0 ? "工作副本没有待提交的变更" : "发现 \(changed) 个项目发生变更"
        }
    }

    private func filterBar(counts: [SvnDockStatusFilter: Int]) -> some View {
        ViewThatFits(in: .horizontal) {
            filterButtons(counts: counts, showsAllCounts: true)
            filterButtons(counts: counts, showsAllCounts: false)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func filterButtons(counts: [SvnDockStatusFilter: Int], showsAllCounts: Bool) -> some View {
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
                        if showsAllCounts || isSelected {
                            Text(filter == .ignored && !store.hasLoadedIgnoredEntries ? "—" : count.formatted())
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(
                                    isSelected ? Color.white.opacity(0.22) : SvnDockTheme.secondaryText.opacity(0.09),
                                    in: Capsule()
                                )
                        }
                    }
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? SvnDockTheme.onAccent : SvnDockTheme.secondaryText)
                    .fixedSize(horizontal: true, vertical: false)
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
                .accessibilityLabel(filter == .ignored && !store.hasLoadedIgnoredEntries ? "已忽略，点击加载" : "\(filter.displayName)，\(count) 项")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .help(filter == .ignored && !store.hasLoadedIgnoredEntries ? "点击读取已忽略项目" : "\(filter.displayName)：\(count) 项")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
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

    private var treeToolbar: some View {
        HStack(spacing: 10) {
            Label("目录树", systemImage: "list.bullet.indent")
                .foregroundStyle(SvnDockTheme.secondaryText)
            Spacer(minLength: 0)
            Button { collapsedPaths = statusTree.directoryPaths } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .help("全部收起")
            .accessibilityLabel("收起全部目录")
            Button { collapsedPaths = [] } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("展开已载入的目录")
            .accessibilityLabel("展开已载入的目录")
            Menu {
                Toggle("合并连续的空目录层级", isOn: $compactDirectories)
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .font(.system(size: 11))
        .buttonStyle(.plain)
        .disabled(store.isInteractionBlocked)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var statusTree: SvnDockStatusTree {
        var entries = store.displayedEntries
        var seen = Set(entries.map(\.id))
        func collect(_ entry: SvnDockStatusEntry) {
            guard store.isDirectoryExpanded(entry) else { return }
            for child in store.visibleDirectoryChildren(for: entry) {
                if seen.insert(child.id).inserted { entries.append(child) }
                collect(child)
            }
        }
        for entry in store.displayedEntries { collect(entry) }
        return SvnDockStatusTree(entries: entries, compact: compactDirectories)
    }

    private func isExpanded(_ node: SvnDockStatusTree.Node) -> Bool {
        !collapsedPaths.contains(node.path) && (!node.children.isEmpty
            || node.entry.map { store.isDirectoryExpanded($0) } == true)
    }

    private func toggle(_ node: SvnDockStatusTree.Node) {
        if isExpanded(node) {
            collapsedPaths.insert(node.path)
        } else {
            collapsedPaths.remove(node.path)
            if let entry = node.entry, store.canExpandDirectory(entry),
               !store.isDirectoryExpanded(entry) {
                store.toggleDirectoryExpansion(for: entry)
            }
        }
    }

    private var statusTreeRows: [StatusTreeRow] {
        var rows: [StatusTreeRow] = []
        func append(_ node: SvnDockStatusTree.Node, depth: Int) {
            rows.append(.init(id: "tree::" + node.path, depth: depth, kind: .node(node)))
            guard isExpanded(node) else { return }
            for child in node.children { append(child, depth: depth + 1) }
            if let entry = node.entry {
                if store.isLoadingDirectory(entry) {
                    rows.append(.loading(parent: entry, depth: depth + 1))
                } else if let message = store.directoryError(for: entry) {
                    rows.append(.error(parent: entry, message: message, depth: depth + 1))
                } else if store.hasMoreDirectoryChildren(for: entry) {
                    rows.append(.more(parent: entry, count: store.remainingDirectoryChildCount(for: entry), depth: depth + 1))
                }
            }
        }
        for root in statusTree.roots { append(root, depth: 0) }
        return rows
    }

    @ViewBuilder
    private func statusTreeRow(_ row: StatusTreeRow) -> some View {
        switch row.kind {
        case let .node(node):
            Group {
                if let entry = node.entry {
                    StatusTreeEntryRowView(
                        store: store, entry: entry, depth: row.depth,
                        childCount: node.children.reduce(0) { $0 + $1.itemCount },
                        canExpand: !node.children.isEmpty || store.canExpandDirectory(entry),
                        expanded: isExpanded(node), toggle: { toggle(node) },
                        openDiffWindow: openDiffWindow(for:)
                    )
                    .tag(entry.id)
                } else {
                    Button { toggle(node) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isExpanded(node) ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold)).frame(width: 16)
                            Image(systemName: isExpanded(node) ? "folder.fill" : "folder")
                                .foregroundStyle(SvnDockTheme.secondaryText).frame(width: 18)
                            Text(node.name).lineLimit(1).truncationMode(.middle)
                            Text("\(node.itemCount) 项").foregroundStyle(.secondary).font(.system(size: 11))
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 12))
                        .padding(.leading, CGFloat(row.depth) * 16 + 6)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(node.path + "（分组目录，仅用于导航）")
                }
            }
            .svnDockCardSelection()
            .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
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

    private func openDiffWindow(for entry: SvnDockStatusEntry) {
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

private struct StatusTreeRow: Identifiable {
    enum Kind {
        case node(SvnDockStatusTree.Node)
        case loading(parent: SvnDockStatusEntry)
        case error(parent: SvnDockStatusEntry, message: String)
        case more(parent: SvnDockStatusEntry, count: Int)
    }

    let id: String
    let depth: Int
    let kind: Kind

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
    let childCount: Int
    let canExpand: Bool
    let expanded: Bool
    let toggle: () -> Void
    let openDiffWindow: (SvnDockStatusEntry) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SvnDockTheme.secondaryText)
                    .frame(width: 16, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canExpand)
            .opacity(canExpand ? 1 : 0)
            .accessibilityLabel(expanded ? "收起目录" : "展开目录")
            StatusTreeFileIcon(entry: entry)
            Text(entry.fileName)
                .font(.system(size: 12, weight: entry.nodeKind == .directory ? .medium : .regular))
                .foregroundStyle(entry.status == .unversioned ? SvnDockTheme.text : entry.status.tint)
                .lineLimit(1).truncationMode(.middle)
                .layoutPriority(1)
            if childCount > 0 {
                Text("\(childCount) 项").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            if entry.switchedAncestorPath != nil {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.orange)
                    .help("此项目位于已切换分支的子树")
            }
            if let remote = entry.repositoryStatus, remote != .clean {
                Image(systemName: "arrow.down.circle").foregroundStyle(remote.tint)
                    .help("仓库端：\(remote.displayName)")
            }
            Text(entry.status.displayName)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(entry.status.tint)
                .fixedSize()
        }
        .padding(.leading, CGFloat(depth) * 16 + 6)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(store.selectedEntryIDs.contains(entry.id) ? SvnDockTheme.selection : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .help(entry.relativePath + " · " + entry.status.displayName
              + (entry.missingDescendantCount > 0 ? " · 含 \(entry.missingDescendantCount) 个缺失子项" : ""))
        .contextMenu { entryContextMenu }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var entryContextMenu: some View {
        let selection = StatusActionSelection.context(for: entry, selectedEntries: store.selectedEntries)
        let multiple = selection.entries.count > 1
        let conflicts = selection.entries.filter { $0.status == .conflicted }

        if multiple {
            Text("已选择 \(selection.entries.count) 项")
        }

        if !selection.addableEntries.isEmpty {
            Button("添加 \(selection.countLabel(selection.addableEntries.count)) 到 SVN") {
                store.selectedEntryIDs = selection.entryIDs
                let ids = Set(selection.addableEntries.map(\.id))
                Task { await store.addSelectedEntries(entryIDs: ids) }
            }
            .disabled(store.isInteractionBlocked)
            if selection.addableEntries.count < selection.entries.count {
                Text("仅添加未纳管项目和已添加目录的内容")
            }
        }

        if multiple, !selection.revertibleEntries.isEmpty {
            Button("还原 \(selection.countLabel(selection.revertibleEntries.count))…", role: .destructive) {
                store.selectedEntryIDs = selection.entryIDs
                store.requestRevertConfirmation()
            }
            .disabled(store.isInteractionBlocked)
            if selection.revertibleEntries.count < selection.entries.count {
                Text("仅还原有本地变更的已纳管项目")
            }
        }

        if !conflicts.isEmpty {
            Button("审阅 \(selection.countLabel(conflicts.count)) 冲突…") {
                store.requestResolveConfirmation(for: entry, preserveSelection: true)
            }
            .disabled(store.isInteractionBlocked)
            if conflicts.count < selection.entries.count {
                Text("仅处理选中的冲突项目，审阅窗口会列出确切范围")
            }
        }

        if multiple, entry.isMissingVersioned {
            Button("标记 \(selection.entries.count) 项为 SVN 删除…") {
                store.requestMissingDeletion(for: entry)
            }
            .disabled(!store.canScheduleMissingDeletion(for: entry))
        }
        if multiple, entry.isMissingScheduledAddition {
            Button("清理 \(selection.entries.count) 项缺失的添加记录…") {
                store.requestMissingAdditionCleanup(for: entry)
            }
            .disabled(!store.canCleanupMissingAdditions(for: entry))
        }

        if multiple {
            Divider()
            Text("以下操作仅针对：\(entry.fileName)")
        }

        if entry.status == .unversioned {
            Menu("忽略") {
                Button("忽略此名称") {
                    store.requestIgnoreConfirmation(for: entry, mode: .name)
                }
                if entry.nodeKind == .file,
                   !(entry.relativePath as NSString).pathExtension.isEmpty {
                    Button("忽略所有 .\((entry.relativePath as NSString).pathExtension) 文件") {
                        store.requestIgnoreConfirmation(for: entry, mode: .fileExtension)
                    }
                }
            }
        }

        if entry.status == .ignored {
            Button("取消忽略…") {
                Task { await store.requestIgnoreRemoval(for: entry) }
            }
            .disabled(store.isInteractionBlocked || store.isLoadingIgnoredEntries)
        }

        if entry.status.isChange {
            if entry.nodeKind == .file && entry.status != .missing {
                Button("在窗口中查看差异") {
                    openDiffWindow(entry)
                }
            }
            if entry.status == .missing {
                if entry.isMissingVersioned && !multiple {
                    Button("标记为 SVN 删除…") {
                        store.requestMissingDeletion(for: entry)
                    }
                    .disabled(!store.canScheduleMissingDeletion(for: entry))
                }
                if entry.isMissingScheduledAddition && !multiple {
                    Button("清理缺失的添加记录…") {
                        store.requestMissingAdditionCleanup(for: entry)
                    }
                    .disabled(!store.canCleanupMissingAdditions(for: entry))
                }
                if entry.isMissingVersioned && !multiple {
                    Button("还原 1 项已纳管项目…", role: .destructive) {
                        guard store.canScheduleMissingDeletion(for: entry) else { return }
                        if !store.selectedEntryIDs.contains(entry.id) {
                            store.selectedEntryIDs = [entry.id]
                        }
                        store.requestRevertConfirmation()
                    }
                    .disabled(!store.canScheduleMissingDeletion(for: entry))
                }
            } else if entry.status == .added {
                Button("取消添加…") {
                    store.requestUnscheduleAddConfirmation(for: entry)
                }
            } else if !multiple {
                Button("还原 1 项…", role: .destructive) {
                    store.selectedEntryIDs = selection.entryIDs
                    store.requestRevertConfirmation()
                }
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
}

struct StatusTreeFileIcon: View {
    let entry: SvnDockStatusEntry

    private var fileType: (String, Color)? {
        switch (entry.relativePath as NSString).pathExtension.lowercased() {
        case "js", "jsx", "mjs", "cjs": ("JS", .orange)
        case "ts", "tsx": ("TS", .blue)
        case "vue": ("V", SvnDockTheme.green)
        case "swift": ("S", .orange)
        case "java", "kt": ("J", .orange)
        case "py": ("PY", .blue)
        case "json", "yml", "yaml": ("{}", .purple)
        case "md", "txt": ("M", SvnDockTheme.secondaryText)
        default: nil
        }
    }

    var body: some View {
        Group {
            if entry.nodeKind == .directory {
                Image(systemName: "folder.fill").foregroundStyle(SvnDockTheme.accent.opacity(0.75))
            } else if let (label, color) = fileType {
                Text(label).font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
                    .frame(width: 17, height: 17)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "doc").foregroundStyle(SvnDockTheme.secondaryText)
            }
        }
        .frame(width: 18, height: 20)
        .accessibilityHidden(true)
    }
}
