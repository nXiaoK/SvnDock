import AppKit
import SwiftUI

struct CommitSheet: View {
    @ObservedObject var store: SvnDockStore

    @State private var message = ""
    @State private var includedEntryIDs: Set<SvnDockStatusEntry.ID>
    @State private var previewEntryID: SvnDockStatusEntry.ID?
    @State private var showsDiffPreview = true
    @State private var isPreviewExpanded = false
    @State private var previewText = ""
    @State private var previewError: String?
    @State private var isLoadingPreview = false

    init(store: SvnDockStore) {
        self.store = store
        let committableIDs = Set(store.committableEntries.map(\.id))
        let selectedCommittableIDs = store.selectedEntryIDs.intersection(committableIDs)
        let includedIDs = store.selectedEntryIDs.isEmpty
            ? committableIDs
            : selectedCommittableIDs
        _includedEntryIDs = State(initialValue: includedIDs)
        _previewEntryID = State(initialValue:
            store.committableEntries.first(where: { includedIDs.contains($0.id) })?.id
                ?? store.committableEntries.first?.id
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if isPreviewExpanded {
                    expandedHeader
                } else {
                    VStack(spacing: 0) {
                        header
                        summary.padding(.horizontal, 24)
                        messageEditor.padding(24)
                    }
                }
            }
            Divider().overlay(SvnDockTheme.border)
            // Keep the diff in the same branch when changing layout so its
            // display mode, font size and scroll position remain intact.
            HStack(spacing: 0) {
                if !isPreviewExpanded {
                    fileSelection
                        .frame(minWidth: 350, maxWidth: showsDiffPreview ? 410 : .infinity)
                }
                if showsDiffPreview {
                    if !isPreviewExpanded { Divider().overlay(SvnDockTheme.border) }
                    diffPreview
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(SvnDockTheme.border)
            Group {
                if isPreviewExpanded { expandedFooter }
                else { footer }
            }
        }
        .foregroundStyle(SvnDockTheme.text)
        .background(SvnDockTheme.surface)
        .tint(SvnDockTheme.accent)
        .frame(minWidth: 940, idealWidth: 940, maxWidth: 1100,
               minHeight: 720, idealHeight: 800, maxHeight: 900)
        .interactiveDismissDisabled(store.isBusy)
        .task(id: previewRequest) {
            await loadPreview(for: previewRequest)
        }
        .onChange(of: store.committableEntries.map(\.id)) { _, ids in
            includedEntryIDs.formIntersection(ids)
            if let previewEntryID, !ids.contains(previewEntryID) {
                self.previewEntryID = ids.first
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "arrow.up")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(SvnDockTheme.onAccent)
                .frame(width: 46, height: 46)
                .background {
                    Circle().fill(
                        LinearGradient(colors: [SvnDockTheme.accent.opacity(0.85), SvnDockTheme.accent],
                                       startPoint: .top, endPoint: .bottom)
                    )
                }
                .shadow(color: SvnDockTheme.accent.opacity(0.22), radius: 5, y: 3)
            VStack(alignment: .leading, spacing: 5) {
                Text("提交到 SVN")
                    .font(.system(size: 21, weight: .semibold))
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
            }
            Spacer(minLength: 12)
            Button {
                store.cancelCommit()
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
            .accessibilityLabel("取消提交")
        }
        .padding(24)
    }

    private var summary: some View {
        HStack(spacing: 0) {
            summaryItem(symbol: "doc.text", title: "\(includedEntries.count) 个文件",
                        detail: "已选择 \(includedEntries.count) / \(store.committableEntries.count) 个文件")
            Divider().frame(height: 42)
            summaryItem(symbol: "plus.forwardslash.minus", title: "提交范围",
                        detail: selectedStatusSummary, color: SvnDockTheme.green)
            Divider().frame(height: 42)
            summaryItem(symbol: "point.3.connected.trianglepath.dotted", title: "工作副本",
                        detail: store.selectedWorkingCopy?.revision.map { "当前版本 r\($0)" } ?? "版本信息未获取")
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

    private var messageEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("提交说明").font(.system(size: 14, weight: .semibold))
            ZStack(alignment: .topLeading) {
                if message.isEmpty {
                    Text("描述本次修改的目的和影响…")
                        .font(.system(size: 14))
                        .foregroundStyle(SvnDockTheme.secondaryText.opacity(0.75))
                        .padding(.horizontal, 15)
                        .padding(.top, 16)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $message)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .padding(.bottom, 22)
                    .disabled(store.isBusy)
                    .accessibilityLabel("提交说明")
            }
            .frame(height: 104)
            .overlay(alignment: .bottomTrailing) {
                Text("\(message.count) 字")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(SvnDockTheme.secondaryText)
                    .padding(12)
                    .allowsHitTesting(false)
            }
            .svnDockSurface(cornerRadius: 9)
        }
    }

    private var fileSelection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("待提交文件  （\(store.committableEntries.count)）")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    if includedEntries.count == store.committableEntries.count {
                        includedEntryIDs.removeAll()
                    } else {
                        includedEntryIDs = Set(store.committableEntries.map(\.id))
                    }
                } label: {
                    Text(includedEntries.count == store.committableEntries.count ? "全部取消" : "全部选择")
                        .font(.system(size: 12))
                        .foregroundStyle(SvnDockTheme.accent)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SvnDockPlainButtonStyle())
                .disabled(store.isBusy)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(store.committableEntries) { entry in fileRow(entry) }
                }
                .padding(1)
            }
            .frame(maxHeight: .infinity)
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
        .padding(20)
    }

    private func fileRow(_ entry: SvnDockStatusEntry) -> some View {
        let isPreviewed = previewEntryID == entry.id
        return HStack(spacing: 0) {
            Toggle("包含 \(entry.fileName)", isOn: inclusionBinding(for: entry))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: 36, height: 62)
                .contentShape(Rectangle())
                .disabled(store.isBusy)
            Button {
                previewEntryID = entry.id
            } label: {
                HStack(spacing: 11) {
                    SvnDockFileIcon(entry: entry, size: 40)
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
                .padding(.vertical, 11)
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

    private var diffPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !isPreviewExpanded {
                HStack {
                    Text("文件差异预览").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button {
                        isPreviewExpanded = true
                    } label: {
                        Label("放大查看", systemImage: "arrow.up.left.and.arrow.down.right")
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
            if let entry = previewEntry {
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
        .padding(20)
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
            Text("已选择 \(includedEntries.count) 个文件 · 提交说明已保留")
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
        if store.entries.contains(where: { $0.status == .missing }) {
            Label(
                "本地缺失项目无法直接提交。请先恢复文件，或处理其 SVN 添加、删除状态；提交父目录仍可能包含缺失项。",
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

    private var footer: some View {
        HStack(spacing: 10) {
            Label("将提交 \(includedEntries.count) 个文件到 SVN", systemImage: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(SvnDockTheme.secondaryText)
            Spacer()
            Button("取消") {
                store.cancelCommit()
            }
            .buttonStyle(SvnDockButtonStyle())
            .keyboardShortcut(.cancelAction)
            .disabled(store.isBusy)
            Button {
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
                || includedEntries.isEmpty
            )
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(SvnDockTheme.subtleSurface.opacity(0.55))
    }

    private var includedEntries: [SvnDockStatusEntry] {
        store.committableEntries.filter { includedEntryIDs.contains($0.id) }
    }

    private var selectedStatusSummary: String {
        let entries = includedEntries
        let changed = entries.filter { $0.status == .modified || $0.status == .replaced }.count
        let added = entries.filter { $0.status == .added }.count
        let deleted = entries.filter { $0.status == .deleted }.count
        return "修改 \(changed) · 新增 \(added) · 删除 \(deleted)"
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
