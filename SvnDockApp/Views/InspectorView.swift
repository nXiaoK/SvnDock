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
            SelectionInspector(store: store)
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

private struct SelectionInspector: View {
    @ObservedObject var store: SvnDockStore

    private var selection: StatusActionSelection { .init(entries: store.selectedEntries) }

    var body: some View {
        let selection = self.selection
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("已选择 \(selection.entries.count) 项", systemImage: "square.stack.3d.up")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(SvnDockTheme.text)
                Text("\(selection.entries.count - selection.directoryCount) 个文件 · \(selection.directoryCount) 个目录")
                    .font(.system(size: 13))
                    .foregroundStyle(SvnDockTheme.secondaryText)

                VStack(spacing: 10) {
                    ForEach(SvnDockStatusKind.allCases, id: \.self) { status in
                        let count = selection.entries.filter { $0.status == status }.count
                        if count > 0 {
                            HStack {
                                SvnDockStatusPill(status: status)
                                Spacer()
                                Text("\(count) 项").monospacedDigit()
                            }
                        }
                    }
                }
                .padding(16)
                .svnDockSurface(cornerRadius: 9)

                VStack(alignment: .leading, spacing: 10) {
                    Button("添加 \(selection.countLabel(selection.addableEntries.count)) 到 SVN") {
                        let ids = Set(selection.addableEntries.map(\.id))
                        Task { await store.addSelectedEntries(entryIDs: ids) }
                    }
                    .disabled(selection.addableEntries.isEmpty || store.isInteractionBlocked)
                    Text("添加仅处理未纳管项目和已添加目录的内容；目录包含其子项。")
                        .font(.caption)
                        .foregroundStyle(SvnDockTheme.secondaryText)
                    Button("还原 \(selection.countLabel(selection.revertibleEntries.count))…", role: .destructive) {
                        store.requestRevertConfirmation()
                    }
                    .disabled(selection.revertibleEntries.isEmpty || store.isInteractionBlocked)
                    Text("还原仅处理有本地变更的已纳管项目；确认时可检查路径及目录范围。未纳管和未更改项目不受影响。")
                        .font(.caption)
                        .foregroundStyle(SvnDockTheme.secondaryText)
                }
                .buttonStyle(SvnDockButtonStyle())

                Text("选择单个项目可查看内容或属性差异。冲突解决、忽略和历史查询可从对应项目的右键菜单进入。")
                    .font(.system(size: 12))
                    .foregroundStyle(SvnDockTheme.secondaryText)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DiffInspector: View {
    @ObservedObject var store: SvnDockStore
    let entry: SvnDockStatusEntry
    @StateObject private var presentationModel = DiffPresentationModel()
    @State private var localPreview: LocalFilePreview?
    @State private var previewReload = 0

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
                                       statistics: store.isLoadingDiff || store.diffText.isEmpty
                                           ? nil : presentationModel.statistics)
                        .frame(width: 208)
                }
            }
        }
        .onChange(of: store.diffText) { _, text in
            if text.isEmpty { presentationModel.clear() }
        }
        .task(id: "\(entry.id)::\(entry.status.rawValue)::\(entry.fileSize ?? 0)::\(entry.modifiedAt?.timeIntervalSince1970 ?? 0)::\(previewReload)") {
            guard entry.status == .unversioned, entry.nodeKind != .directory,
                  let rootURL = store.selectedWorkingCopy?.rootURL else { return }
            localPreview = nil
            let relativePath = entry.relativePath
            let task = Task.detached(priority: .userInitiated) {
                LocalFilePreview.read(relativePath: relativePath, rootURL: rootURL)
            }
            let result = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            guard !Task.isCancelled else { return }
            localPreview = result
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
                    message: missingEntryMessage
                )
                if entry.isMissingVersioned {
                    Button("标记为 SVN 删除…") {
                        store.requestMissingDeletion(for: entry)
                    }
                    .buttonStyle(SvnDockButtonStyle())
                    .disabled(store.isInteractionBlocked)
                    .padding(.bottom, 24)
                } else if entry.isMissingScheduledAddition {
                    Button("清理缺失的添加记录…") {
                        store.requestMissingAdditionCleanup(for: entry)
                    }
                    .buttonStyle(SvnDockButtonStyle())
                    .disabled(store.isInteractionBlocked)
                    .padding(.bottom, 24)
                }
            }
        } else if let error = store.diffLoadError {
            VStack(spacing: 12) {
                SvnDockEmptyState(symbol: "exclamationmark.triangle", title: "无法读取差异", message: error)
                Button("重试") { Task { await store.loadDiffForSelection() } }
                    .buttonStyle(SvnDockButtonStyle())
                    .disabled(store.isInteractionBlocked)
                    .padding(.bottom, 24)
            }
        } else if entry.nodeKind == .directory && store.diffText.isEmpty {
            SvnDockEmptyState(
                symbol: "folder",
                title: entry.status == .unversioned ? "目录尚未纳管" : "目录自身没有属性差异",
                message: entry.status == .unversioned
                    ? "展开目录并选择文件，可以在添加到 SVN 前预览内容。"
                    : "此处只检查目录自身的属性。选择子文件可查看其内容差异。"
            )
        } else if entry.status == .unversioned {
            unversionedContent
        } else if store.diffText.isEmpty {
            SvnDockEmptyState(
                symbol: "doc.text",
                title: "没有文本差异",
                message: "SVN 未返回内容或属性差异。文件可能与基础版本一致；可刷新状态后重新检查。"
            )
        } else {
            DiffContentView(text: store.diffText, presentationModel: presentationModel)
                .id(entry.id)
        }
    }

    @ViewBuilder
    private var unversionedContent: some View {
        switch localPreview {
        case nil:
            ProgressView("正在读取文件…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .text(text):
            VStack(spacing: 0) {
                Text("未纳管文件 · 只读内容预览 · UTF-8")
                    .font(.caption)
                    .foregroundStyle(SvnDockTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(SvnDockTheme.subtleSurface)
                if text.isEmpty {
                    SvnDockEmptyState(symbol: "doc", title: "空文件", message: "此文件尚未包含任何内容。")
                } else {
                    DiffRawTextView(text: text)
                }
            }
        case let .tooLarge(limit):
            SvnDockEmptyState(symbol: "doc", title: "文件过大，未载入预览",
                              message: "只读预览支持不超过 \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) 的文本。可通过右键菜单在 Finder 中显示文件。")
        case .binary:
            SvnDockEmptyState(symbol: "doc.zipper", title: "二进制内容无法显示为文本",
                              message: "文件包含非文本字节。可在 Finder 中使用合适的应用检查内容。")
        case .unsupportedEncoding:
            SvnDockEmptyState(symbol: "character.textbox", title: "暂不支持此文本编码",
                              message: "只读预览目前支持 UTF-8。文件内容未被更改，可在外部编辑器中查看。")
        case .unsupportedType:
            SvnDockEmptyState(symbol: "doc.badge.ellipsis", title: "此项目不支持内容预览",
                              message: "只读预览仅支持普通文件。")
        case let .unavailable(message):
            VStack(spacing: 12) {
                SvnDockEmptyState(symbol: "exclamationmark.triangle", title: "无法读取文件", message: message)
                Button("重试") { previewReload += 1 }
                    .buttonStyle(SvnDockButtonStyle())
                    .padding(.bottom, 24)
            }
        }
    }

    private var missingEntryMessage: String {
        if entry.isMissingVersioned {
            return "这是已经纳管的项目。要从仓库删除，请先标记为 SVN 删除，再提交这次删除；目录包含其子项。若只是误删，可通过右键菜单还原文件。"
        }
        if entry.isMissingScheduledAddition {
            return "这是添加后尚未提交就被删除的项目，可以清理其添加记录。目录会连同缺失子项一起处理。"
        }
        return "此项目的 SVN 状态尚未确认或存在冲突。请刷新状态并检查后再处理。"
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
                if entry.status == .unversioned {
                    Text("工作副本 · 只读预览")
                } else if entry.nodeKind == .directory {
                    Text("BASE → 工作副本 · 目录自身属性")
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
                if entry.status == .unversioned {
                    previewReload += 1
                } else {
                    Task { await store.loadDiffForSelection() }
                }
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
