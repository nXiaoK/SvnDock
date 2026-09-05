import AppKit
import SwiftUI
import SvnDockCore

struct HistoryRevisionView: View {
    let request: SvnDockRevisionRequest
    let expanded: Bool
    @StateObject private var model: HistoryRevisionModel
    @State private var reloadID = UUID()
    @State private var showsMessage = false
    @Environment(\.openWindow) private var openWindow

    init(store: SvnDockStore, request: SvnDockRevisionRequest, expanded: Bool = false) {
        self.request = request
        self.expanded = expanded
        _model = StateObject(wrappedValue: HistoryRevisionModel(store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            revisionHeader
            Divider()
            if model.isLoading {
                ProgressView("正在读取本次提交的变更文件…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage {
                errorState("无法读取提交详情", message: error) { reloadID = UUID() }
            } else if let details = model.details, details.changes.isEmpty {
                ContentUnavailableView("没有可显示的路径", systemImage: "doc.text",
                    description: Text("该版本没有可访问的文件变更，或当前账号无法读取变更路径。"))
            } else if model.details != nil {
                if expanded {
                    HSplitView {
                        changedFiles.frame(minWidth: 240, idealWidth: 310, maxWidth: 480)
                        filePreview.frame(minWidth: 480)
                    }
                } else {
                    VSplitView {
                        changedFiles.frame(minHeight: 90, idealHeight: 130, maxHeight: 220)
                        filePreview.frame(minHeight: 160)
                    }
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: reloadID) { await model.load(request) }
        .onDisappear { model.cancel() }
    }

    private var revisionHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: "r\(request.revision)")
                    .font(.system(.headline, design: .monospaced))
                if let entry = model.details?.entry {
                    Text(entry.author ?? "未知作者")
                        .font(.caption)
                        .lineLimit(1)
                    Text(entry.date?.formatted(date: .abbreviated, time: .shortened) ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if !expanded {
                    Button {
                        openExpanded(path: model.selectedPath)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .frame(width: 32, height: 32)
                    }
                    .help("在独立窗口中查看提交详情")
                    .accessibilityLabel("放大提交详情")
                }
                Button { reloadID = UUID() } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 32, height: 32)
                }
                    .disabled(model.isLoading)
                    .help("重新读取本次提交")
                    .accessibilityLabel("刷新提交详情")
            }
            .buttonStyle(SvnDockPlainButtonStyle())
            if let entry = model.details?.entry {
                HStack(alignment: .top, spacing: 6) {
                    Text(entry.message.isEmpty ? "（无提交说明）" : entry.message)
                        .font(.callout)
                        .lineLimit(expanded ? 2 : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(entry.message)
                    Button { showsMessage = true } label: {
                        Image(systemName: "text.bubble")
                            .frame(width: 32, height: 32)
                    }
                        .buttonStyle(SvnDockPlainButtonStyle())
                        .help("查看完整提交说明")
                        .accessibilityLabel("完整提交说明")
                        .popover(isPresented: $showsMessage) {
                            ScrollView {
                                Text(entry.message.isEmpty ? "（无提交说明）" : entry.message)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                            }
                            .frame(width: 440, height: 240)
                        }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .contextMenu {
            Button("复制版本号") { copy("r\(request.revision)") }
            if let message = model.details?.entry.message {
                Button("复制提交说明") { copy(message) }
            }
        }
    }

    private var changedFiles: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("筛选本次提交的路径", text: $model.pathQuery)
                    .textFieldStyle(.plain)
                if !model.pathQuery.isEmpty {
                    Button { model.pathQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .frame(width: 32, height: 32)
                    }
                        .buttonStyle(SvnDockPlainButtonStyle())
                        .accessibilityLabel("清除路径筛选")
                }
            }
            .font(.caption)
            .padding(8)
            Divider()
            if model.isFiltering {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.filteredChanges.isEmpty {
                Text("没有匹配的路径")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(selection: Binding(get: { model.selectedPath }, set: { model.select($0) })) {
                        ForEach(model.displayedChanges) { change in
                            HistoryChangedPathRow(change: change)
                                .tag(change.path)
                                .id(change.path)
                                .onTapGesture(count: 2) {
                                    model.select(change.path)
                                    if !expanded { openExpanded(path: change.path) }
                                }
                                .contextMenu {
                                    Button("复制仓库路径") { copy(change.path) }
                                    if let source = change.copyFromPath {
                                        Button("复制来源路径") { copy(source) }
                                    }
                                    if !expanded {
                                        Button("在独立窗口中查看本次提交") { openExpanded(path: change.path) }
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: model.selectedPath) { _, path in
                        if let path { proxy.scrollTo(path) }
                    }
                }
            }
            Divider()
            HStack(spacing: 6) {
                Text("\(model.filteredChanges.count) / \(model.details?.changes.count ?? 0) 项")
                    .help("匹配路径 / 本次提交的全部变更路径；包含目录及可访问的仓库其他路径。")
                Spacer(minLength: 0)
                if model.filteredChanges.count > model.visibleLimit {
                    Button { model.showMore() } label: {
                        Text("加载更多")
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                    }
                    .buttonStyle(SvnDockPlainButtonStyle())
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
        }
    }

    private var filePreview: some View {
        VStack(spacing: 0) {
            if let change = model.selectedChange {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(change.path)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(change.path)
                        if let source = change.copyFromPath, let revision = change.copyFromRevision {
                            Text("来源 r\(revision) · \(source)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help("\(source) @ r\(revision)" + (change.isMove ? "；SVN 将移动记录为复制与删除。" : ""))
                        }
                    }
                    Spacer(minLength: 0)
                    Button { model.moveSelection(by: -1) } label: {
                        Image(systemName: "chevron.up")
                            .frame(width: 32, height: 32)
                    }
                        .disabled((model.selectionIndex ?? 0) == 0)
                        .help("上一项")
                        .accessibilityLabel("上一个变更文件")
                    Button { model.moveSelection(by: 1) } label: {
                        Image(systemName: "chevron.down")
                            .frame(width: 32, height: 32)
                    }
                        .disabled((model.selectionIndex ?? 0) + 1 >= model.filteredChanges.count)
                        .help("下一项")
                        .accessibilityLabel("下一个变更文件")
                    Button { model.select(change.path, force: true) } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 32, height: 32)
                    }
                        .disabled(model.isLoadingDiff)
                        .help("重新读取该文件的历史差异")
                }
                .buttonStyle(SvnDockPlainButtonStyle())
                .padding(8)
                Divider()
                if model.isLoadingDiff {
                    ProgressView("正在读取 r\(request.revision) 的文件差异…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.diffErrorMessage {
                    errorState("无法读取历史差异", message: error) { model.select(change.path, force: true) }
                } else if model.diffText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("没有文本变化", systemImage: change.kind == .directory ? "folder" : "doc.on.doc",
                        description: Text(emptyDiffMessage(for: change)))
                } else {
                    DiffContentView(
                        text: model.diffText, initialMode: expanded ? .sideBySide : .unified,
                        oldTitle: "r\(change.comparesCopySource ? change.copyFromRevision ?? request.revision - 1 : request.revision - 1)",
                        newTitle: "r\(request.revision)"
                    )
                    .id("\(request.id)::\(change.path)")
                }
            } else {
                ContentUnavailableView("选择变更文件", systemImage: "doc.text.magnifyingglass",
                    description: Text("选择本次提交中的一个路径，预览提交前后的差异。"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func emptyDiffMessage(for change: SVNChangedPath) -> String {
        if change.kind == .directory { return "该目录本身没有属性差异。目录中的文件已分别列出，可选择文件查看内容。" }
        if change.comparesCopySource { return "文件内容与复制来源相同。本次提交只改变了路径或新增了一份副本。" }
        return "该路径在此次提交中没有可显示的文本或属性差异。"
    }

    private func errorState(_ title: String, message: String, retry: @escaping () -> Void) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message).textSelection(.enabled)
        } actions: {
            Button("重试", action: retry)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openExpanded(path: String?) {
        openWindow(value: SvnDockRevisionRequest(workingCopyID: request.workingCopyID,
                                                revision: request.revision, preferredPath: path))
    }
}

private struct HistoryChangedPathRow: View {
    let change: SVNChangedPath

    var body: some View {
        HStack(spacing: 8) {
            Text(actionLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
            Image(systemName: change.kind == .directory ? "folder" : "doc.text")
                .foregroundStyle(.secondary)
            Text(change.path)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(change.path)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(actionLabel)，\(change.path)")
    }

    private var actionLabel: String {
        if change.isMove { return "移动" }
        if change.comparesCopySource { return "复制" }
        return switch change.action {
        case .added: "新增"
        case .modified: "修改"
        case .deleted: "删除"
        case .replaced: "替换"
        case .unknown: "变更"
        }
    }
    private var tint: Color {
        if change.isMove || change.comparesCopySource { return .purple }
        return switch change.action {
        case .added: .green
        case .deleted: .red
        case .replaced: .orange
        default: .blue
        }
    }
}
