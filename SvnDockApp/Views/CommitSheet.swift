import AppKit
import SwiftUI

struct CommitSheet: View {
    @ObservedObject var store: SvnDockStore

    @State private var draftWorkingCopy: SvnDockWorkingCopy?
    @State private var message = ""
    @State private var includedEntryIDs: Set<SvnDockStatusEntry.ID>
    @State private var selectionSummary: SelectionSummary
    @State private var previewEntryID: SvnDockStatusEntry.ID?
    @State private var showsDiffPreview = true
    @State private var isPreviewExpanded = false
    @State private var previewText = ""
    @State private var previewError: String?
    @State private var isLoadingPreview = false
    @State private var pathQuery = ""
    @State private var showsIncludedOnly = false
    @State private var draftNotice: String
    @State private var draftError: String?
    @State private var isConfirmingDraftClear = false
    @State private var showsScopeDetails = false

    init(store: SvnDockStore) {
        self.store = store
        let workingCopy = store.selectedWorkingCopy
        var savedDraft: SvnDockCommitDraft?
        var loadError: String?
        if let workingCopy {
            do {
                savedDraft = try store.commitDraftStore.draft(for: workingCopy)
            } catch {
                loadError = "无法恢复草稿：\(error.localizedDescription)"
            }
        }
        let explicitIDs = store.commitInitialSelectedEntryIDs
        let excludedIDs = store.commitInitiallyExcludedEntryIDs
        let includedIDs: Set<SvnDockStatusEntry.ID> = loadError != nil && explicitIDs == nil ? [] : SvnDockCommitDraft.initialIncludedEntryIDs(
            entries: store.committableEntries,
            selectedEntryIDs: store.selectedEntryIDs,
            savedDraft: savedDraft,
            explicitEntryIDs: explicitIDs,
            excludedEntryIDs: excludedIDs
        )
        _draftWorkingCopy = State(initialValue: workingCopy)
        _message = State(initialValue: savedDraft?.message ?? "")
        let notice = explicitIDs != nil
            ? "已按本次 Finder 选择勾选；提交说明继续使用草稿"
            : savedDraft == nil ? "说明与勾选自动保留" : "已恢复此工作副本的草稿；新变更未自动勾选"
        _draftNotice = State(initialValue: excludedIDs.isEmpty ? notice
            : notice + "；工作区隐藏的 \(excludedIDs.count) 项未勾选，可在此重新勾选")
        _draftError = State(initialValue: loadError)
        _includedEntryIDs = State(initialValue: includedIDs)
        _selectionSummary = State(initialValue: SelectionSummary(
            entries: store.committableEntries, includedIDs: includedIDs
        ))
        _previewEntryID = State(initialValue:
            store.committableEntries.first(where: {
                $0.relativePath == savedDraft?.previewRelativePath
                    && (explicitIDs == nil || includedIDs.contains($0.id))
            })?.id
                ?? store.committableEntries.first(where: { includedIDs.contains($0.id) })?.id
                ?? store.committableEntries.first?.id
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 860
            VStack(spacing: 0) {
                Group {
                    if isPreviewExpanded {
                        expandedHeader
                    } else {
                        VStack(spacing: 0) {
                            header(compact: compact)
                            if compact {
                                compactSummary
                                    .padding(.horizontal, 16)
                            } else {
                                summary.padding(.horizontal, 24)
                            }
                            messageEditor(compact: compact)
                                .padding(.horizontal, compact ? 16 : 24)
                                .padding(.vertical, compact ? 10 : 24)
                        }
                    }
                }
                Divider().overlay(SvnDockTheme.border)
                // Keep the diff in the same branch when changing layout so its
                // display mode, font size and scroll position remain intact.
                HStack(spacing: 0) {
                    if !isPreviewExpanded {
                        fileSelection(compact: compact)
                            .frame(minWidth: 350, maxWidth: showsDiffPreview ? 410 : .infinity)
                    }
                    if showsDiffPreview {
                        if !isPreviewExpanded { Divider().overlay(SvnDockTheme.border) }
                        diffPreview(compact: compact)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                Divider().overlay(SvnDockTheme.border)
                Group {
                    if isPreviewExpanded { expandedFooter }
                    else { footer(compact: compact) }
                }
            }
        }
        .foregroundStyle(SvnDockTheme.text)
        .background(SvnDockTheme.surface)
        .tint(SvnDockTheme.accent)
        .frame(minWidth: 940, idealWidth: 940, maxWidth: 1100,
               minHeight: 640, idealHeight: 800, maxHeight: 900)
        .interactiveDismissDisabled(store.isBusy)
        .task(id: previewRequest) {
            await loadPreview(for: previewRequest)
        }
        .onAppear {
            if draftError == nil { persistDraft() }
        }
        .onChange(of: message) { _, _ in persistDraft() }
        .onChange(of: previewEntryID) { _, _ in persistDraft() }
        .onChange(of: includedEntryIDs) { _, ids in
            selectionSummary = SelectionSummary(entries: store.committableEntries, includedIDs: ids)
            persistDraft()
        }
        .onChange(of: store.committableEntries) { _, entries in
            guard isCurrentDraftWorkingCopy else { return }
            let ids = Set(entries.map(\.id))
            includedEntryIDs.formIntersection(ids)
            selectionSummary = SelectionSummary(entries: entries, includedIDs: includedEntryIDs)
            if let previewEntryID, !ids.contains(previewEntryID) {
                self.previewEntryID = entries.first?.id
            }
        }
        .alert("清空提交草稿？", isPresented: $isConfirmingDraftClear) {
            Button("清空草稿", role: .destructive) { clearDraft() }
            Button("保留草稿", role: .cancel) {}
        } message: {
            Text("清空此工作副本的提交说明与文件勾选。文件内容不会改变。")
        }
    }

    private func header(compact: Bool) -> some View {
        HStack(spacing: compact ? 12 : 16) {
            Image(systemName: "arrow.up")
                .font(.system(size: compact ? 18 : 23, weight: .semibold))
                .foregroundStyle(SvnDockTheme.onAccent)
                .frame(width: compact ? 34 : 46, height: compact ? 34 : 46)
                .background {
                    Circle().fill(
                        LinearGradient(colors: [SvnDockTheme.accent.opacity(0.85), SvnDockTheme.accent],
                                       startPoint: .top, endPoint: .bottom)
                    )
                }
                .shadow(color: SvnDockTheme.accent.opacity(0.22), radius: 5, y: 3)
            VStack(alignment: .leading, spacing: 5) {
                Text("提交到 SVN")
                    .font(.system(size: compact ? 18 : 21, weight: .semibold))
                HStack(spacing: 10) {
                    Text(store.selectedWorkingCopy?.name ?? "未选择工作副本")
                        .fontWeight(.medium)
                    if let path = store.selectedWorkingCopy?.rootURL.path {
                        Text(path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(SvnDockTheme.secondaryText)
                Text(store.commitWorkingCopy?.repositoryURL?.absoluteString ?? "仓库地址待确认，请刷新工作副本")
                    .font(.system(size: 11))
                    .foregroundStyle(SvnDockTheme.secondaryText)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Button {
                closeKeepingDraft()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SvnDockTheme.secondaryText)
                    .frame(width: 32, height: 32)
                    .background(SvnDockTheme.subtleSurface, in: Circle())
                    .contentShape(Rectangle())
            }
            .buttonStyle(SvnDockPlainButtonStyle(cornerRadius: 16))
            .disabled(store.isBusy)
            .help("关闭并保留草稿")
            .accessibilityLabel("关闭并保留草稿")
        }
        .padding(.horizontal, compact ? 16 : 24)
        .padding(.vertical, compact ? 12 : 24)
    }

    private var compactSummary: some View {
        HStack(spacing: 12) {
            Label("已选择 \(selectionSummary.count) / \(store.committableEntries.count) 项", systemImage: "doc.text")
                .foregroundStyle(SvnDockTheme.accent)
            Text(selectedStatusSummary)
                .foregroundStyle(SvnDockTheme.secondaryText)
            Spacer(minLength: 4)
            Text(store.selectedWorkingCopy?.revision.map { "根目录基线 r\($0)" } ?? "版本信息未获取")
                .foregroundStyle(SvnDockTheme.secondaryText)
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(SvnDockTheme.subtleSurface, in: RoundedRectangle(cornerRadius: 8))
    }

    private var summary: some View {
        HStack(spacing: 0) {
            summaryItem(symbol: "doc.text", title: "\(selectionSummary.count) 个项目",
                        detail: "已选择 \(selectionSummary.count) / \(store.committableEntries.count) 个项目")
            Divider().frame(height: 42)
            summaryItem(symbol: "plus.forwardslash.minus", title: "提交范围",
                        detail: selectedStatusSummary, color: SvnDockTheme.green)
            Divider().frame(height: 42)
            summaryItem(symbol: "point.3.connected.trianglepath.dotted", title: "工作副本",
                        detail: store.selectedWorkingCopy?.revision.map { "根目录基线 r\($0)" } ?? "版本信息未获取")
        }
        .padding(.vertical, 18)
        .svnDockSurface(cornerRadius: 12)
    }

    private func summaryItem(symbol: String, title: String, detail: String,
                             color: Color = SvnDockTheme.accent) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .background(color.opacity(0.07), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(SvnDockTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func messageEditor(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 12) {
            HStack {
                Text("提交说明").font(.system(size: 14, weight: .semibold))
                if compact {
                    Text("\(message.count) 字")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(SvnDockTheme.secondaryText)
                }
                Spacer()
                Text(draftError ?? draftNotice)
                    .font(.system(size: 11))
                    .foregroundStyle(draftError == nil ? SvnDockTheme.secondaryText : .orange)
                    .lineLimit(2)
                Button("清空草稿…") { isConfirmingDraftClear = true }
                    .buttonStyle(SvnDockButtonStyle())
                    .disabled(store.isBusy || (message.isEmpty && includedEntryIDs.isEmpty))
            }
            ZStack(alignment: .topLeading) {
                if message.isEmpty {
                    Text("描述本次修改的目的和影响…")
                        .font(.system(size: compact ? 13 : 14))
                        .foregroundStyle(SvnDockTheme.secondaryText.opacity(0.75))
                        .padding(.horizontal, compact ? 13 : 15)
                        .padding(.top, compact ? 12 : 16)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $message)
                    .font(.system(size: compact ? 13 : 14))
                    .scrollContentBackground(.hidden)
                    .padding(compact ? 8 : 10)
                    .padding(.bottom, compact ? 0 : 22)
                    .disabled(store.isBusy)
                    .accessibilityLabel("提交说明")
            }
            .frame(height: compact ? 76 : 104)
            .overlay(alignment: .bottomTrailing) {
                if !compact {
                    Text("\(message.count) 字")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(SvnDockTheme.secondaryText)
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
            .svnDockSurface(cornerRadius: 9)
        }
    }

    private func fileSelection(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 16) {
            HStack {
                Text("待提交项目  （\(store.committableEntries.count)）")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    if allVisibleEntriesIncluded {
                        includedEntryIDs.subtract(filteredEntryIDs)
                    } else {
                        includedEntryIDs.formUnion(filteredEntryIDs)
                    }
                } label: {
                    Text(allVisibleEntriesIncluded ? "取消筛选结果" : "全选筛选结果")
                        .font(.system(size: 12))
                        .foregroundStyle(SvnDockTheme.accent)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SvnDockPlainButtonStyle())
                .disabled(store.isBusy || filteredEntries.isEmpty)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(SvnDockTheme.secondaryText)
                TextField("筛选提交路径…", text: $pathQuery)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("筛选提交路径")
                if !pathQuery.isEmpty {
                    Button { pathQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除路径筛选")
                }
            }
            .padding(compact ? 7 : 9)
            .svnDockSurface(cornerRadius: 8)
            Toggle("仅看已包含项目（\(selectionSummary.count)）", isOn: $showsIncludedOnly)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            ScrollView {
                LazyVStack(spacing: compact ? 6 : 8) {
                    ForEach(filteredEntries) { entry in fileRow(entry, compact: compact) }
                    if filteredEntries.isEmpty {
                        Text("没有符合筛选条件的项目")
                            .font(.system(size: 12))
                            .foregroundStyle(SvnDockTheme.secondaryText)
                            .padding(.vertical, 20)
                    }
                }
                .padding(1)
            }
            .frame(maxHeight: .infinity)
            .layoutPriority(1)
            if compact {
                HStack(spacing: 8) {
                    Toggle("显示差异预览", isOn: $showsDiffPreview)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                    if hasSafetyNotices {
                        Button {
                            showsScopeDetails = true
                        } label: {
                            Label(compactNoticeTitle, systemImage: "info.circle")
                                .font(.system(size: 11))
                                .padding(.horizontal, 6)
                                .frame(minHeight: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(SvnDockPlainButtonStyle())
                        .foregroundStyle(SvnDockTheme.accent)
                        .help("查看目录操作范围及未包含项目的提示")
                        .popover(isPresented: $showsScopeDetails) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("提交范围与提示").font(.headline)
                                    safetyNotices
                                }
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(width: 390, height: 280)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $showsDiffPreview) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("显示差异预览").font(.system(size: 13, weight: .medium))
                            Text("在右侧查看所选文件的代码差异")
                                .font(.system(size: 11))
                                .foregroundStyle(SvnDockTheme.secondaryText)
                        }
                    }
                    .toggleStyle(.checkbox)
                    safetyNotices
                }
            }
        }
        .padding(compact ? 12 : 20)
    }

    private func fileRow(_ entry: SvnDockStatusEntry, compact: Bool) -> some View {
        let isPreviewed = previewEntryID == entry.id
        return HStack(spacing: 0) {
            Toggle("包含 \(entry.fileName)", isOn: inclusionBinding(for: entry))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: 36, height: compact ? 50 : 62)
                .contentShape(Rectangle())
                .disabled(store.isBusy)
            Button {
                previewEntryID = entry.id
            } label: {
                HStack(spacing: 11) {
                    SvnDockFileIcon(entry: entry, size: compact ? 32 : 40)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.fileName)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(parentDirectory(for: entry))
                            .font(.system(size: 11))
                            .foregroundStyle(SvnDockTheme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 3)
                    SvnDockStatusPill(status: entry.status)
                }
                .padding(.vertical, compact ? 7 : 11)
                .padding(.trailing, 11)
                .padding(.leading, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(SvnDockPlainButtonStyle(cornerRadius: 9))
            .help("预览 \(entry.relativePath)")
        }
        .background(isPreviewed ? SvnDockTheme.selection : SvnDockTheme.surface,
                    in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isPreviewed ? SvnDockTheme.accent.opacity(0.16) : SvnDockTheme.border,
                              lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private func diffPreview(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            if !isPreviewExpanded {
                HStack {
                    if compact, let entry = previewEntry {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.fileName)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(parentDirectory(for: entry))
                                .font(.system(size: 11))
                                .foregroundStyle(SvnDockTheme.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .help(entry.relativePath)
                        SvnDockStatusPill(status: entry.status)
                    } else {
                        Text("文件差异预览").font(.system(size: 14, weight: .semibold))
                    }
                    Spacer()
                    Button {
                        isPreviewExpanded = true
                    } label: {
                        Label(compact ? "放大" : "放大查看", systemImage: "arrow.up.left.and.arrow.down.right")
                            .padding(.horizontal, 8)
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SvnDockPlainButtonStyle())
                    .foregroundStyle(SvnDockTheme.accent)
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(previewEntry == nil)
                    .help("放大差异预览（⇧⌘F）")
                    .accessibilityIdentifier("commit.expandPreview")
                }
            }
            if let entry = previewEntry, !compact || isPreviewExpanded {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 18))
                        .foregroundStyle(SvnDockTheme.secondaryText)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.fileName)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(parentDirectory(for: entry))
                            .font(.system(size: 11))
                            .foregroundStyle(SvnDockTheme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    SvnDockStatusPill(status: entry.status)
                }
            }
            Group {
                if isLoadingPreview {
                    ProgressView("正在读取差异…")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let previewError {
                    previewPlaceholder(symbol: "exclamationmark.triangle", title: "无法读取差异",
                                       detail: previewError)
                } else if previewEntry == nil {
                    previewPlaceholder(symbol: "doc.text.magnifyingglass", title: "选择一个文件",
                                       detail: "点击左侧文件查看本次提交的修改内容。")
                } else if previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    previewPlaceholder(symbol: "doc.text", title: "没有文本差异",
                                       detail: "此文件没有可显示的文本修改。")
                } else {
                    DiffContentView(text: previewText)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(SvnDockTheme.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .padding(compact ? 12 : 20)
        .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var expandedHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(SvnDockTheme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("查看提交差异")
                    .font(.system(size: 18, weight: .semibold))
                Text(store.selectedWorkingCopy?.name ?? "工作副本")
                    .font(.system(size: 12))
                    .foregroundStyle(SvnDockTheme.secondaryText)
            }
            Spacer()
            Button {
                isPreviewExpanded = false
            } label: {
                Label("返回提交", systemImage: "arrow.down.right.and.arrow.up.left")
                    .contentShape(Rectangle())
            }
            .buttonStyle(SvnDockButtonStyle())
            .keyboardShortcut(.cancelAction)
            .help("收起预览并继续编辑提交说明（Esc）")
            .accessibilityIdentifier("commit.collapsePreview")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var expandedFooter: some View {
        HStack(spacing: 10) {
            Text("已选择 \(selectionSummary.count) 个项目 · 提交说明已保留")
                .font(.system(size: 12))
                .foregroundStyle(SvnDockTheme.secondaryText)
            Spacer()
            Text("\(previewEntryIndex.map { $0 + 1 } ?? 0) / \(store.committableEntries.count)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(SvnDockTheme.secondaryText)
                .padding(.trailing, 4)
            Button {
                movePreview(by: -1)
            } label: {
                Label("上一个文件", systemImage: "chevron.left")
            }
            .buttonStyle(SvnDockButtonStyle())
            .disabled(previewEntryIndex == nil || previewEntryIndex == 0)
            Button {
                movePreview(by: 1)
            } label: {
                Label("下一个文件", systemImage: "chevron.right")
            }
            .buttonStyle(SvnDockButtonStyle())
            .disabled(previewEntryIndex == nil || previewEntryIndex == store.committableEntries.count - 1)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(SvnDockTheme.subtleSurface.opacity(0.55))
    }

    private var previewEntryIndex: Int? {
        store.committableEntries.firstIndex { $0.id == previewEntryID }
    }

    private func movePreview(by offset: Int) {
        guard let index = previewEntryIndex,
              store.committableEntries.indices.contains(index + offset) else { return }
        previewEntryID = store.committableEntries[index + offset].id
    }

    private func previewPlaceholder(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(SvnDockTheme.accent.opacity(0.6))
            Text(title).font(.system(size: 14, weight: .medium))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(SvnDockTheme.secondaryText)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SvnDockTheme.subtleSurface)
    }

    @ViewBuilder
    private var safetyNotices: some View {
        if !includedSwitchedEntries.isEmpty {
            Label("所选项目包含已切换分支的子树，无法从当前根工作副本提交：\(includedSwitchedEntries.map(\.relativePath).joined(separator: "、"))。请在目标分支的独立工作副本中检查并提交。", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(SvnDockTheme.red)
                .textSelection(.enabled)
        }
        if !includedDirectoryOperations.isEmpty {
            DisclosureGroup("目录操作范围（\(includedDirectoryOperations.count) 项）") {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(includedDirectoryOperations) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.relativePath).fontWeight(.medium)
                                .textSelection(.enabled)
                            Text(entry.status == .added
                                 ? "新增子项目需逐项勾选。若为复制目录，会包含原目录结构；未勾选的本地子项修改仍保留。"
                                 : "删除或替换会影响仓库中的整个目录树，不能按子文件拆分。")
                        }
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(SvnDockTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 5)
            }
            .font(.system(size: 12))
        }
        if store.entries.contains(where: { $0.status == .missing }) {
            Label(
                "本地缺失项目无法直接提交。请先恢复文件，或处理其 SVN 添加、删除状态。",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
        if store.entries.contains(where: { $0.status == .conflicted }) {
            Label("冲突文件已自动排除", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        }
    }

    private func footer(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Label("将提交 \(selectionSummary.count) 个项目到 SVN", systemImage: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(SvnDockTheme.secondaryText)
            Spacer()
            Button("关闭并保留草稿") {
                closeKeepingDraft()
            }
            .buttonStyle(SvnDockButtonStyle())
            .keyboardShortcut(.cancelAction)
            .disabled(store.isBusy)
            Button {
                persistDraft()
                store.commit(message: message, entryIDs: includedEntryIDs)
            } label: {
                HStack(spacing: 12) {
                    if store.isBusy { ProgressView().controlSize(.small) }
                    Text(store.isBusy ? "正在提交…" : "提交")
                    Text("⌘ ↵").opacity(0.7).font(.system(size: 11))
                }
                .frame(minWidth: 88)
            }
            .buttonStyle(SvnDockButtonStyle(primary: true))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(
                store.isBusy
                || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || selectionSummary.count == 0
                || !includedSwitchedEntries.isEmpty
            )
        }
        .padding(.horizontal, 24)
        .padding(.vertical, compact ? 10 : 16)
        .background(SvnDockTheme.subtleSurface.opacity(0.55))
    }

    private var selectedStatusSummary: String {
        "修改 \(selectionSummary.changed) · 新增 \(selectionSummary.added) · 删除 \(selectionSummary.deleted)"
    }

    private var includedDirectoryOperations: [SvnDockStatusEntry] {
        store.committableEntries.filter {
            includedEntryIDs.contains($0.id) && $0.nodeKind == .directory
                && [.added, .deleted, .replaced].contains($0.status)
        }
    }

    private var hasSafetyNotices: Bool {
        !includedDirectoryOperations.isEmpty
            || !includedSwitchedEntries.isEmpty
            || store.entries.contains { $0.status == .missing || $0.status == .conflicted }
    }

    private var compactNoticeTitle: String {
        if !includedSwitchedEntries.isEmpty { return "已切换分支：提交已阻止" }
        if !includedDirectoryOperations.isEmpty { return "目录范围与提示（\(includedDirectoryOperations.count)）" }
        let missing = store.entries.contains { $0.status == .missing }
        let conflicted = store.entries.contains { $0.status == .conflicted }
        return missing && conflicted ? "冲突 / 缺失未包含" : conflicted ? "冲突项目未包含" : "缺失项目未包含"
    }

    private var filteredEntries: [SvnDockStatusEntry] {
        let query = pathQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.committableEntries.filter {
            (!showsIncludedOnly || includedEntryIDs.contains($0.id))
                && (query.isEmpty || $0.relativePath.localizedStandardContains(query))
        }
    }

    private var includedSwitchedEntries: [SvnDockStatusEntry] {
        store.committableEntries.filter { includedEntryIDs.contains($0.id) && $0.switchedAncestorPath != nil }
    }

    private var filteredEntryIDs: Set<SvnDockStatusEntry.ID> {
        Set(filteredEntries.map(\.id))
    }

    private var allVisibleEntriesIncluded: Bool {
        !filteredEntries.isEmpty && filteredEntryIDs.isSubset(of: includedEntryIDs)
    }

    private var isCurrentDraftWorkingCopy: Bool {
        guard let draftWorkingCopy, let selected = store.selectedWorkingCopy else { return false }
        return selected.id == draftWorkingCopy.id
            && selected.rootURL.standardizedFileURL == draftWorkingCopy.rootURL.standardizedFileURL
    }

    private func persistDraft() {
        // The store removes a draft after confirmed success. SwiftUI may then
        // deliver selection/preview changes from the status refresh; those
        // callbacks must not recreate the completed draft.
        guard !store.isBusy, store.isPresentingCommit, isCurrentDraftWorkingCopy,
              let draftWorkingCopy else { return }
        let paths = Set(store.committableEntries.lazy
            .filter { includedEntryIDs.contains($0.id) }.map(\.relativePath))
        do {
            try store.commitDraftStore.save(SvnDockCommitDraft(
                message: message,
                includedRelativePaths: paths,
                previewRelativePath: previewEntry?.relativePath
            ), for: draftWorkingCopy)
            draftError = nil
        } catch {
            draftError = "无法保存草稿：\(error.localizedDescription)"
        }
    }

    private func clearDraft() {
        message = ""
        includedEntryIDs = []
        previewEntryID = nil
        draftNotice = "草稿已清空；重新勾选要提交的项目"
        // Persist an empty selection so reopening does not silently include
        // every currently changed file after the user clears the draft.
        persistDraft()
    }

    private func closeKeepingDraft() {
        persistDraft()
        store.cancelCommit()
    }

    private struct SelectionSummary {
        var count = 0
        var changed = 0
        var added = 0
        var deleted = 0

        init(entries: [SvnDockStatusEntry], includedIDs: Set<SvnDockStatusEntry.ID>) {
            for entry in entries where includedIDs.contains(entry.id) {
                count += 1
                switch entry.status {
                case .modified, .replaced: changed += 1
                case .added: added += 1
                case .deleted: deleted += 1
                default: break
                }
            }
        }
    }

    private var previewEntry: SvnDockStatusEntry? {
        store.committableEntries.first { $0.id == previewEntryID }
    }

    private var previewRequest: SvnDockDiffRequest? {
        guard showsDiffPreview, let entry = previewEntry else { return nil }
        return SvnDockDiffRequest(workingCopyID: entry.workingCopyID, relativePath: entry.relativePath)
    }

    private func parentDirectory(for entry: SvnDockStatusEntry) -> String {
        let path = (entry.relativePath as NSString).deletingLastPathComponent
        return path.isEmpty || path == "." ? "/" : "/\(path)"
    }

    private func loadPreview(for request: SvnDockDiffRequest?) async {
        previewText = ""
        previewError = nil
        isLoadingPreview = request != nil
        guard let request else { return }
        do {
            let text = try await store.diffText(for: request)
            guard !Task.isCancelled, request == previewRequest else { return }
            previewText = text
            isLoadingPreview = false
        } catch {
            guard !Task.isCancelled, request == previewRequest else { return }
            previewError = error.localizedDescription
            isLoadingPreview = false
        }
    }

    private func inclusionBinding(for entry: SvnDockStatusEntry) -> Binding<Bool> {
        Binding(
            get: { includedEntryIDs.contains(entry.id) },
            set: { isIncluded in
                if isIncluded { includedEntryIDs.insert(entry.id) }
                else { includedEntryIDs.remove(entry.id) }
            }
        )
    }
}
