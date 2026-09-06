import Foundation
import SwiftUI

/// Reviews the frozen request, independently from the main window selection.
/// The service revalidates conflict state before applying the chosen strategy.
struct ConflictReviewSheet: View {
    private struct PreviewID: Equatable {
        let reviewID: UUID
        let entryID: String?
        let reloadID: UUID
    }

    @ObservedObject var store: SvnDockStore
    let review: SvnDockConflictReview
    @State private var selectedEntryID: String?
    @State private var resolution = SvnDockConflictResolution.working
    @State private var hasReviewed = false
    @State private var previewText = ""
    @State private var previewError: String?
    @State private var isLoadingPreview = false
    @State private var loadedPreviewID: PreviewID?
    @State private var reloadID = UUID()

    init(store: SvnDockStore, review: SvnDockConflictReview) {
        self.store = store
        self.review = review
        _selectedEntryID = State(initialValue: review.entries.first?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if review.excludedSelectionCount > 0 {
                Text("本次仅处理 \(review.entries.count) 个冲突项目；原选择中的 \(review.excludedSelectionCount) 个其他项目不在本次范围内。")
                    .font(.system(size: 12))
                    .foregroundStyle(SvnDockTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(SvnDockTheme.subtleSurface)
                Divider()
            }
            HSplitView {
                pathList
                    .frame(minWidth: 230, idealWidth: 260, maxWidth: 330)
                preview
                    .frame(minWidth: 570, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            resolutionControls
        }
        .frame(width: 960, height: 600)
        .background(SvnDockTheme.surface)
        .foregroundStyle(SvnDockTheme.text)
        .tint(SvnDockTheme.accent)
        .task(id: currentPreviewID) {
            await loadPreview()
        }
        .onChange(of: resolution) { _, _ in hasReviewed = false }
        .onChange(of: review.id) { _, _ in
            selectedEntryID = review.entries.first?.id
            resolution = .working
            hasReviewed = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("审阅并处理冲突", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                Text("\(review.entries.count) 项")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(SvnDockTheme.secondaryText)
            }
            Text("\(review.workingCopy.name) · \(review.workingCopy.rootURL.path(percentEncoded: false))")
                .font(.system(size: 12))
                .foregroundStyle(SvnDockTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(review.workingCopy.rootURL.path(percentEncoded: false))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var pathList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("本次处理范围")
                .font(.system(size: 12, weight: .semibold))
                .padding(12)
            Divider()
            List(selection: $selectedEntryID) {
                ForEach(review.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(entry.relativePath, systemImage: entry.nodeKind == .directory ? "folder" : "doc.text")
                            .font(.system(size: 12, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(conflictTypes(for: entry))
                            .font(.system(size: 11))
                            .foregroundStyle(SvnDockTheme.red)
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tag(entry.id)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(entry.relativePath)，\(conflictTypes(for: entry))")
                }
            }
            .listStyle(.plain)
        }
    }

    private var selectedEntry: SvnDockStatusEntry? {
        review.entries.first { $0.id == selectedEntryID }
    }

    private var currentPreviewID: PreviewID {
        PreviewID(reviewID: review.id, entryID: selectedEntryID, reloadID: reloadID)
    }

    private var preview: some View {
        VStack(spacing: 0) {
            if let entry = selectedEntry {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text("当前内容与基线的差异")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button {
                            hasReviewed = false
                            reloadID = UUID()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(SvnDockPlainButtonStyle())
                        .disabled(isLoadingPreview)
                        .help("重新读取当前项目的差异")
                        .accessibilityLabel("刷新冲突差异")
                    }
                    Text(guidance(for: entry))
                        .font(.system(size: 12))
                        .foregroundStyle(SvnDockTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(SvnDockTheme.subtleSurface)
                Divider()

                if isLoadingPreview || loadedPreviewID != currentPreviewID {
                    ProgressView("正在读取当前差异…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let previewError {
                    SvnDockEmptyState(symbol: "exclamationmark.triangle", title: "无法预览当前差异",
                                      message: previewError, actionTitle: "重试") {
                        hasReviewed = false
                        reloadID = UUID()
                    }
                } else if previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    SvnDockEmptyState(symbol: "doc.text.magnifyingglass", title: "没有可显示的差异",
                                      message: "这不代表冲突已解决。请在外部检查文件内容、属性或路径结构，处理完成后再确认。")
                } else {
                    DiffContentView(text: previewText, oldTitle: "BASE · 基线", newTitle: "当前工作副本")
                        .id("\(review.id)::\(entry.id)")
                }
            } else {
                SvnDockEmptyState(symbol: "doc.text.magnifyingglass", title: "选择冲突项目",
                                  message: "从左侧选择一个项目，审阅当前差异与处理指引。")
            }
        }
    }

    private var resolutionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("处理方式").font(.system(size: 12, weight: .semibold))
                if review.allowsFileReplacement {
                    Picker("处理方式", selection: $resolution) {
                        ForEach(SvnDockConflictResolution.allCases) { strategy in
                            Text(strategyTitle(strategy)).tag(strategy)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 350)
                } else {
                    Text(strategyTitle(.working)).font(.system(size: 12))
                }
                Spacer()
            }
            Text(resolution == .working
                 ? "此操作不会自动合并内容或修复路径。它仅将范围内的冲突标记为已解决；随后检查本地变更，按需提交到仓库。"
                 : "将用所选来源替换本次范围内 \(review.entries.count) 个文件的全部内容并标记已解决，当前编辑可能丢失。此处仅预览现状，未展示替换后的内容；随后检查本地变更，按需提交到仓库。")
                .font(.system(size: 12))
                .foregroundStyle(resolution == .working ? SvnDockTheme.secondaryText : SvnDockTheme.red)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $hasReviewed) {
                Text(resolution == .working
                     ? "我已检查并处理这些项目，确认当前内容、属性及目录结构正确"
                     : "我已检查所选来源并保留需要的内容，确认覆盖上述文件的全部内容并标记已解决")
                    .font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("conflicts.reviewed")
            HStack {
                Text("关闭窗口不会执行处理。")
                    .font(.system(size: 11))
                    .foregroundStyle(SvnDockTheme.secondaryText)
                Spacer()
                Button("关闭", role: .cancel) { store.cancelResolveConfirmation() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SvnDockButtonStyle())
                Button(role: resolution == .working ? nil : .destructive) {
                    store.confirmResolve(using: resolution, reviewed: true, reviewID: review.id)
                } label: {
                    Text(resolution == .working ? "标记 \(review.entries.count) 项已解决" : "替换并标记 \(review.entries.count) 项已解决")
                }
                .buttonStyle(SvnDockButtonStyle(primary: true))
                .disabled(!hasReviewed || review.entries.isEmpty || store.activeOperation != nil)
                .accessibilityIdentifier("conflicts.confirm")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func conflictTypes(for entry: SvnDockStatusEntry) -> String {
        let kinds: [SvnDockConflictKind] = [.text, .property, .tree]
        let names = kinds.filter { entry.conflictKinds.contains($0) }.map(\.displayName)
        return names.isEmpty ? "冲突类型待确认" : names.joined(separator: " · ")
    }

    private func guidance(for entry: SvnDockStatusEntry) -> String {
        var messages: [String] = []
        if entry.conflictKinds.contains(.text) {
            messages.append("内容冲突：请先在编辑器或合并工具中检查文件；二进制文件需用对应应用处理。")
        }
        if entry.conflictKinds.contains(.property) {
            messages.append("属性冲突：请先核对并修正冲突属性的值，再保留当前工作状态。")
        }
        if entry.conflictKinds.contains(.tree) {
            messages.append("树冲突：请先处理删除、移动或阻挡关系，确认路径结构正确；文本差异无法证明结构冲突已处理。")
        }
        return messages.isEmpty ? "请先检查文件、属性和目录结构，确认冲突来源及正确结果。" : messages.joined(separator: "\n")
    }

    private func strategyTitle(_ strategy: SvnDockConflictResolution) -> String {
        switch strategy {
        case .working: "保留当前工作状态（标记已解决）"
        case .mineFull: "整文件使用更新前的本地版本"
        case .theirsFull: "整文件使用仓库传入版本"
        case .base: "整文件使用共同基线版本"
        }
    }

    private func loadPreview() async {
        previewText = ""
        previewError = nil
        isLoadingPreview = false
        guard let entry = selectedEntry else { return }
        let requestID = PreviewID(reviewID: review.id, entryID: entry.id, reloadID: reloadID)
        loadedPreviewID = requestID
        isLoadingPreview = true
        defer {
            if requestID == PreviewID(reviewID: review.id, entryID: selectedEntryID, reloadID: reloadID) {
                isLoadingPreview = false
            }
        }
        let task = Task { try await store.conflictDiff(for: entry, in: review) }
        do {
            let text = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard !Task.isCancelled,
                  requestID == PreviewID(reviewID: review.id, entryID: selectedEntryID, reloadID: reloadID) else { return }
            previewText = text
        } catch is CancellationError {
            if !Task.isCancelled,
               requestID == PreviewID(reviewID: review.id, entryID: selectedEntryID, reloadID: reloadID) {
                previewError = "差异读取已取消，可重试后继续检查。"
            }
            return
        } catch {
            guard !Task.isCancelled,
                  requestID == PreviewID(reviewID: review.id, entryID: selectedEntryID, reloadID: reloadID) else { return }
            previewError = error.localizedDescription
        }
    }
}
