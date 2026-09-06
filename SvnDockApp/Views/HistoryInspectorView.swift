import AppKit
import Foundation
import SwiftUI

struct HistoryInspectorView: View {
    @ObservedObject var store: SvnDockStore

    @State private var query = SvnDockHistoryQuery()
    @State private var revisionInput = ""
    @State private var revisionInputError: String?
    @State private var selectedRevision: Int?
    @State private var selectedTargetID: String?
    @State private var showsCompactDetail = false
    @State private var isRevisionJumpExpanded = false
    @State private var compactSelectionTask: Task<Void, Never>?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let entries = query.filter(store.historyEntries)
        GeometryReader { geometry in
            let compact = geometry.size.height < minimumSplitHeight
            Group {
                if compact, showsCompactDetail,
                   store.selectedEntryIDs.count <= 1,
                   let request = revisionRequest(entries: entries) {
                    compactDetail(request: request, entries: entries)
                } else {
                    VStack(spacing: 0) {
                        header
                        Divider()
                        if store.historyTarget != nil && store.selectedEntryIDs.count <= 1 {
                            queryControls
                            Divider()
                        }
                        content(entries: entries, compact: compact)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: compact) { _, isCompact in
                cancelCompactSelection()
                if isCompact, revisionRequest(entries: entries) != nil {
                    showsCompactDetail = true
                }
            }
        }
        .onChange(of: store.historyTarget?.id) { _, _ in
            cancelCompactSelection()
            showsCompactDetail = false
            selectedRevision = nil
            selectedTargetID = nil
            revisionInput = ""
            revisionInputError = nil
        }
        .onChange(of: query) { _, _ in clearFilteredSelection() }
        .onChange(of: store.historyEntries) { _, _ in clearFilteredSelection() }
        .onDisappear { cancelCompactSelection() }
    }

    /// Reserve the detail's own header and split panes before offering the
    /// stacked layout. Search expansion and banners need additional room.
    private var minimumSplitHeight: CGFloat {
        700 + (isRevisionJumpExpanded ? 90 : 0)
            + (store.historyErrorMessage != nil || store.historyIsStale ? 52 : 0)
    }

    private func compactDetail(request: SvnDockRevisionRequest, entries: [SvnDockLogEntry]) -> some View {
        let index = entries.firstIndex { $0.revision == request.revision }
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    cancelCompactSelection()
                    showsCompactDetail = false
                } label: {
                    Label("返回历史", systemImage: "chevron.left")
                        .padding(.horizontal, 6)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                }
                .keyboardShortcut(.escape, modifiers: [])
                .help("返回历史，保留筛选、已载入记录和选择位置")
                .accessibilityIdentifier("history.backToList")
                Spacer(minLength: 4)
                Button { moveCompactSelection(by: -1, entries: entries) } label: {
                    Image(systemName: "chevron.up").frame(width: 30, height: 32)
                        .contentShape(Rectangle())
                }
                .disabled(index == nil || index == 0)
                .help("上一条匹配的提交")
                .accessibilityLabel("上一条提交")
                Text("\((index ?? 0) + 1)/\(entries.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(SvnDockTheme.secondaryText)
                    .fixedSize()
                Button { moveCompactSelection(by: 1, entries: entries) } label: {
                    Image(systemName: "chevron.down").frame(width: 30, height: 32)
                        .contentShape(Rectangle())
                }
                .disabled(index == nil || (index ?? 0) + 1 >= entries.count)
                .help("下一条匹配的提交")
                .accessibilityLabel("下一条提交")
                Button { openWindow(value: request) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 30, height: 32)
                        .contentShape(Rectangle())
                }
                .help("在独立窗口中查看提交详情")
                .accessibilityLabel("放大提交详情")
            }
            .font(.system(size: 12))
            .buttonStyle(SvnDockPlainButtonStyle())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            HistoryRevisionView(store: store, request: request)
                .id(request)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3)
                .foregroundStyle(SvnDockTheme.secondaryText)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(SvnDockTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(headerSubtitle)
            }
            Spacer(minLength: 8)
            Button {
                Task { await store.refreshHistory() }
            } label: {
                Group {
                    if store.isLoadingHistory && !store.isLoadingMoreHistory {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(SvnDockPlainButtonStyle())
            .disabled(store.selectedWorkingCopy == nil || store.isLoadingHistory || store.isLoadingMoreHistory)
            .help("从最新版本重新载入当前范围的历史")
            .accessibilityLabel("刷新提交历史")
        }
        .padding(10)
    }

    private var queryControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("筛选已载入记录", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SvnDockTheme.secondaryText)
                Spacer(minLength: 0)
                if !query.isEmpty {
                    Button("清空筛选") { query = SvnDockHistoryQuery() }
                        .buttonStyle(SvnDockPlainButtonStyle())
                        .font(.system(size: 11))
                        .foregroundStyle(SvnDockTheme.accent)
                }
            }
            HStack(spacing: 8) {
                TextField("说明、作者或版本号", text: $query.text)
                    .accessibilityLabel("筛选已载入记录的说明、作者或版本号")
                    .accessibilityIdentifier("history.filterText")
                TextField("限定作者", text: $query.author)
                    .frame(maxWidth: 110)
                    .accessibilityLabel("限定已载入记录的作者")
                    .accessibilityIdentifier("history.filterAuthor")
            }
            DisclosureGroup("按版本号打开仓库详情", isExpanded: $isRevisionJumpExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("r123 或 123", text: $revisionInput)
                            .onSubmit(openRevision)
                            .accessibilityLabel("输入要查看的仓库版本号")
                            .accessibilityIdentifier("history.revisionInput")
                        Button("查看版本", action: openRevision)
                            .buttonStyle(SvnDockButtonStyle())
                            .disabled(revisionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .fixedSize()
                    }
                    Text(revisionInputError ?? "打开当前仓库的详情；该提交可能不涉及当前路径。")
                        .font(.system(size: 11))
                        .foregroundStyle(revisionInputError == nil ? SvnDockTheme.secondaryText : SvnDockTheme.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            }
            .font(.system(size: 11))
        }
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onChange(of: revisionInput) { _, _ in revisionInputError = nil }
    }

    @ViewBuilder
    private func content(entries: [SvnDockLogEntry], compact: Bool) -> some View {
        if store.selectedWorkingCopy == nil {
            SvnDockEmptyState(symbol: "sidebar.left", title: "选择工作副本",
                              message: "从左侧选择一个工作副本以查看提交历史。")
        } else if store.selectedEntryIDs.count > 1 {
            SvnDockEmptyState(symbol: "square.stack.3d.up", title: "已选择多个项目",
                              message: "一次只能查看一个项目的提交历史。")
        } else if store.historyTarget == nil && store.historyErrorMessage == nil {
            ProgressView("正在准备提交历史…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            historyContent(entries: entries, compact: compact)
        }
    }

    private func historyContent(entries: [SvnDockLogEntry], compact: Bool) -> some View {
        VStack(spacing: 0) {
            if let error = store.historyErrorMessage {
                historyErrorBanner(error)
                Divider()
            } else if store.historyIsStale {
                Label("当前显示此前载入的记录，刷新后查看最新历史。", systemImage: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(SvnDockTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(SvnDockTheme.subtleSurface)
                Divider()
            }

            if store.isLoadingHistory && !store.historyHasLoaded && store.historyEntries.isEmpty {
                ProgressView("正在读取提交历史…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !store.historyHasLoaded && store.historyEntries.isEmpty {
                SvnDockEmptyState(symbol: "exclamationmark.triangle", title: "历史尚未载入",
                                  message: "请重试读取当前范围的提交历史。")
            } else if entries.isEmpty {
                emptyHistory
            } else {
                historyList(entries: entries, compact: compact)
            }
            if compact, let request = revisionRequest(entries: entries) {
                Button {
                    cancelCompactSelection()
                    showsCompactDetail = true
                } label: {
                    Label("查看所选提交 r\(request.revision)", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SvnDockPlainButtonStyle())
                .foregroundStyle(SvnDockTheme.accent)
            }
            Divider()
            historyFooter(visibleCount: entries.count)
        }
    }

    private var emptyHistory: some View {
        SvnDockEmptyState(
            symbol: query.isEmpty ? "clock" : "line.3.horizontal.decrease.circle",
            title: query.isEmpty ? "没有提交记录" : "已载入记录中没有匹配项",
            message: query.isEmpty
                ? "当前范围没有可显示的 SVN 提交历史。"
                : noMatchMessage
        )
    }

    private var noMatchMessage: String {
        let scope = "筛选只检查已载入的 \(store.historyEntries.count) 条记录。"
        if store.historyIsStale { return scope + "可清空筛选或刷新当前范围。" }
        if store.historyHasMore { return scope + "可清空筛选，或继续加载更早记录。" }
        return scope + "可清空筛选或调整条件；当前范围没有更早的可见记录。"
    }

    private func historyList(entries: [SvnDockLogEntry], compact: Bool) -> some View {
        let request = compact ? nil : revisionRequest(entries: entries)
        return VSplitView {
            ScrollViewReader { proxy in
                List(selection: revisionSelection(compact: compact)) {
                    ForEach(entries) { entry in
                        HistoryEntryRow(entry: entry, isSelected: selectedRevision == entry.revision)
                            .tag(entry.revision)
                            .id(entry.revision)
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                Button("在独立窗口中查看提交详情") { openEntry(entry.revision) }
                                Button("复制版本号") { copy("r\(entry.revision)") }
                                Button("复制提交说明") { copy(entry.message) }
                            }
                    }
                }
                .listStyle(.plain)
                .contextMenu(forSelectionType: Int.self) { _ in
                    EmptyView()
                } primaryAction: { revisions in
                    guard revisions.count == 1, let revision = revisions.first else { return }
                    openEntry(revision)
                }
                .onAppear {
                    if let selectedRevision { proxy.scrollTo(selectedRevision, anchor: .center) }
                }
            }
            .frame(minHeight: compact ? 80 : 120, idealHeight: 180, maxHeight: request == nil ? .infinity : 240)

            if let request {
                HistoryRevisionView(store: store, request: request)
                    .id(request)
                    .frame(minHeight: 240)
            }
        }
    }

    private func revisionSelection(compact: Bool) -> Binding<Int?> {
        Binding(get: { selectedRevision }, set: { revision in
            let changed = selectedRevision != revision || selectedTargetID != store.historyTarget?.id
            selectedRevision = revision
            selectedTargetID = store.historyTarget?.id
            cancelCompactSelection()
            guard compact, changed, revision != nil else { return }
            let targetID = selectedTargetID
            // Keep the native row alive long enough to receive a double-click.
            // A primary action cancels this transition and opens its window.
            compactSelectionTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
                } catch { return }
                guard selectedRevision == revision, selectedTargetID == targetID,
                      store.historyTarget?.id == targetID,
                      revisionRequest(entries: query.filter(store.historyEntries)) != nil else { return }
                showsCompactDetail = true
                compactSelectionTask = nil
            }
        })
    }

    private func cancelCompactSelection() {
        compactSelectionTask?.cancel()
        compactSelectionTask = nil
    }

    private func moveCompactSelection(by offset: Int, entries: [SvnDockLogEntry]) {
        guard let revision = selectedRevision,
              let index = entries.firstIndex(where: { $0.revision == revision }),
              entries.indices.contains(index + offset) else { return }
        cancelCompactSelection()
        selectedRevision = entries[index + offset].revision
        selectedTargetID = store.historyTarget?.id
    }

    private func revisionRequest(entries: [SvnDockLogEntry]) -> SvnDockRevisionRequest? {
        guard let revision = SvnDockHistoryQuery.visibleSelection(
            revision: selectedRevision, selectedTargetID: selectedTargetID,
            currentTargetID: store.historyTarget?.id, entries: entries
        ), let target = store.historyTarget else { return nil }
        return SvnDockRevisionRequest(workingCopyID: target.workingCopy.id, revision: revision)
    }

    private func clearFilteredSelection() {
        let visible = query.filter(store.historyEntries)
        selectedRevision = SvnDockHistoryQuery.visibleSelection(
            revision: selectedRevision, selectedTargetID: selectedTargetID,
            currentTargetID: store.historyTarget?.id, entries: visible
        )
        if selectedRevision == nil {
            cancelCompactSelection()
            selectedTargetID = nil
            showsCompactDetail = false
        }
    }

    private func openEntry(_ revision: Int) {
        guard let target = store.historyTarget else { return }
        cancelCompactSelection()
        selectedRevision = revision
        selectedTargetID = target.id
        openWindow(value: SvnDockRevisionRequest(workingCopyID: target.workingCopy.id, revision: revision))
    }

    private func openRevision() {
        guard let revision = SvnDockHistoryQuery.revisionNumber(from: revisionInput) else {
            revisionInputError = "请输入正整数版本号，例如 r123 或 123。"
            return
        }
        guard let target = store.historyTarget else { return }
        // A repository revision is independent from this path's loaded logs.
        // Keep list selection unchanged; the detail loader verifies existence.
        openWindow(value: SvnDockRevisionRequest(workingCopyID: target.workingCopy.id, revision: revision))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func historyErrorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                if store.historyIsStale {
                    Text("刷新失败，以下仍为此前记录")
                        .font(.caption.weight(.medium))
                } else if store.historyHasLoaded {
                    Text("更早记录未载入，已有记录已保留")
                        .font(.caption.weight(.medium))
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(SvnDockTheme.secondaryText)
                    .lineLimit(2)
                    .help(message)
            }
            Spacer(minLength: 8)
            Button("重试") { Task { await store.retryHistory() } }
                .controlSize(.small)
                .disabled(store.isLoadingHistory || store.isLoadingMoreHistory)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private func historyFooter(visibleCount: Int) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                countSummary(visibleCount: visibleCount)
                Spacer(minLength: 8)
                paginationControl
            }
            VStack(alignment: .leading, spacing: 6) {
                countSummary(visibleCount: visibleCount)
                paginationControl
            }
        }
        .font(.caption)
        .foregroundStyle(SvnDockTheme.secondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func countSummary(visibleCount: Int) -> some View {
        Text(query.isEmpty ? "已载入 \(store.historyEntries.count) 条"
             : "匹配 \(visibleCount) / 已载入 \(store.historyEntries.count) 条")
            .fixedSize()
    }

    @ViewBuilder
    private var paginationControl: some View {
        if store.isLoadingMoreHistory || store.isLoadingHistory {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(store.isLoadingMoreHistory ? "正在加载更早记录…" : "正在刷新…")
            }
        } else if store.canLoadMoreHistory {
            Button {
                Task { await store.loadMoreHistory() }
            } label: {
                Text("加载更早记录")
                    .padding(.horizontal, 8)
                    .frame(minHeight: 26)
                    .contentShape(Rectangle())
            }
                .buttonStyle(SvnDockPlainButtonStyle())
                .foregroundStyle(SvnDockTheme.accent)
        } else if store.historyHasLoaded && !store.historyHasMore && !store.historyIsStale
                    && store.historyErrorMessage == nil {
            Text("当前范围没有更早的可见记录")
        }
    }

    private var headerTitle: String {
        store.historyTarget?.title ?? store.selectedWorkingCopy?.name ?? "提交历史"
    }

    private var headerSubtitle: String {
        guard let target = store.historyTarget else {
            return store.selectedWorkingCopy?.rootURL.path(percentEncoded: false) ?? "请选择工作副本"
        }
        if target.relativePaths.isEmpty || target.relativePaths == ["."] {
            return "范围：整个工作副本 · \(target.workingCopy.rootURL.path(percentEncoded: false))"
        }
        return "范围：\(target.relativePaths.joined(separator: "、"))"
    }
}

private struct HistoryEntryRow: View {
    let entry: SvnDockLogEntry
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: "r\(entry.revision)")
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(isSelected ? SvnDockTheme.text : SvnDockTheme.accent)

                Label(author, systemImage: "person.circle")
                    .lineLimit(1)

                Spacer(minLength: 8)

                Label(date, systemImage: "calendar")
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(isSelected ? SvnDockTheme.text.opacity(0.8) : SvnDockTheme.secondaryText)

            Text(message)
                .font(.callout)
                .lineLimit(2)
        }
        .foregroundStyle(SvnDockTheme.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .svnDockCardSelection(isSelected: isSelected)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("版本 \(entry.revision)，\(author)，\(date)，\(message)")
    }

    private var author: String {
        let value = entry.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "未知作者" : value
    }

    private var date: String {
        entry.date?.formatted(date: .abbreviated, time: .shortened) ?? "未知时间"
    }

    private var message: String {
        let value = entry.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "（无提交说明）" : value
    }
}
