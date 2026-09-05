import AppKit
import Foundation
import SwiftUI

struct HistoryInspectorView: View {
    @ObservedObject var store: SvnDockStore

    @State private var retainedEntries: [SvnDockLogEntry] = []
    @State private var retainedTargetID: String?
    @State private var isRequestingMore = false
    @State private var selectedRevision: Int?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear(perform: synchronizeRetainedEntries)
        .onChange(of: store.historyTarget?.id) { _, targetID in
            retainedTargetID = targetID
            retainedEntries = store.historyEntries
            isRequestingMore = false
            selectedRevision = nil
        }
        .onChange(of: store.historyEntries) { _, entries in
            guard !entries.isEmpty else { return }
            retainedTargetID = store.historyTarget?.id
            retainedEntries = entries
        }
        .onChange(of: store.isLoadingHistory) { _, isLoading in
            guard !isLoading else { return }
            isRequestingMore = false
            if store.historyErrorMessage == nil {
                synchronizeRetainedEntries()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(headerSubtitle)
            }

            Spacer(minLength: 8)

            Button {
                isRequestingMore = false
                Task { await store.refreshHistory() }
            } label: {
                Group {
                    if store.isLoadingHistory {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(SvnDockPlainButtonStyle())
            .disabled(store.selectedWorkingCopy == nil || store.isLoadingHistory)
            .help("重新载入提交历史")
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if store.selectedWorkingCopy == nil {
            SvnDockEmptyState(
                symbol: "sidebar.left",
                title: "选择工作副本",
                message: "从左侧选择一个工作副本以查看提交历史。"
            )
        } else if store.selectedEntryIDs.count > 1 {
            SvnDockEmptyState(
                symbol: "square.stack.3d.up",
                title: "已选择多个项目",
                message: "一次只能查看一个项目的提交历史。"
            )
        } else if store.isLoadingHistory && displayedEntries.isEmpty {
            ProgressView("正在读取提交历史…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.historyTarget == nil && store.historyErrorMessage == nil {
            ProgressView("正在准备提交历史…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = store.historyErrorMessage,
                  displayedEntries.isEmpty {
            SvnDockEmptyState(
                symbol: "exclamationmark.triangle",
                title: "无法读取提交历史",
                message: errorMessage,
                actionTitle: "重试"
            ) {
                Task { await store.refreshHistory() }
            }
        } else if displayedEntries.isEmpty {
            SvnDockEmptyState(
                symbol: "clock",
                title: "没有提交记录",
                message: "当前目标没有可显示的 SVN 提交历史。"
            )
        } else {
            historyList
        }
    }

    private var historyList: some View {
        VStack(spacing: 0) {
            if let errorMessage = store.historyErrorMessage {
                historyErrorBanner(errorMessage)
                Divider()
            }

            VSplitView {
                List(selection: $selectedRevision) {
                    ForEach(displayedEntries) { entry in
                        HistoryEntryRow(entry: entry)
                            .tag(entry.revision)
                            .contextMenu {
                                Button("在独立窗口中查看提交详情") {
                                    selectedRevision = entry.revision
                                    if let request = revisionRequest { openWindow(value: request) }
                                }
                                Button("复制版本号") { copy("r\(entry.revision)") }
                                Button("复制提交说明") { copy(entry.message) }
                            }
                    }
                }
                .listStyle(.plain)
                // Let List handle clicks so selection updates before a double-click action.
                .contextMenu(forSelectionType: Int.self) { _ in
                    EmptyView()
                } primaryAction: { revisions in
                    guard revisions.count == 1, let revision = revisions.first else { return }
                    selectedRevision = revision
                    if let request = revisionRequest { openWindow(value: request) }
                }
                .frame(minHeight: 120, idealHeight: 180, maxHeight: revisionRequest == nil ? .infinity : 240)

                if let request = revisionRequest {
                    HistoryRevisionView(store: store, request: request)
                        .id(request)
                        .frame(minHeight: 320)
                }
            }

            Divider()
            historyFooter
        }
    }

    private var revisionRequest: SvnDockRevisionRequest? {
        guard let selectedRevision, let target = store.historyTarget else { return nil }
        return SvnDockRevisionRequest(workingCopyID: target.workingCopy.id, revision: selectedRevision)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func historyErrorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("重试") {
                Task { await store.refreshHistory() }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private var historyFooter: some View {
        HStack(spacing: 10) {
            Text("已显示 \(displayedEntries.count) 条")
            if selectedRevision == nil { Text("选择提交以预览差异").lineLimit(1) }
            Spacer()

            if store.isLoadingHistory {
                ProgressView()
                    .controlSize(.small)
                Text(isRequestingMore ? "正在加载更多…" : "正在刷新…")
            } else if store.canLoadMoreHistory {
                Button {
                    isRequestingMore = true
                    Task {
                        await store.loadMoreHistory()
                        isRequestingMore = false
                    }
                } label: {
                    Text("加载更多")
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                }
                .buttonStyle(SvnDockPlainButtonStyle())
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    private var displayedEntries: [SvnDockLogEntry] {
        if !store.historyEntries.isEmpty {
            return store.historyEntries
        }
        guard retainedTargetID == store.historyTarget?.id else { return [] }
        return retainedEntries
    }

    private var headerTitle: String {
        store.historyTarget?.title
            ?? store.selectedWorkingCopy?.name
            ?? "提交历史"
    }

    private var headerSubtitle: String {
        guard let target = store.historyTarget else {
            return store.selectedWorkingCopy?.rootURL.path(percentEncoded: false)
                ?? "请选择工作副本"
        }

        switch target.relativePaths.count {
        case 0:
            return target.workingCopy.rootURL.path(percentEncoded: false)
        case 1:
            let path = target.relativePaths[0]
            return path == "."
                ? target.workingCopy.rootURL.path(percentEncoded: false)
                : path
        default:
            return "\(target.relativePaths.count) 个项目"
        }
    }

    private func synchronizeRetainedEntries() {
        retainedTargetID = store.historyTarget?.id
        retainedEntries = store.historyEntries
    }
}

private struct HistoryEntryRow: View {
    let entry: SvnDockLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: "r\(entry.revision)")
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.tint)

                Label(author, systemImage: "person.circle")
                    .lineLimit(1)

                Spacer(minLength: 8)

                Label(date, systemImage: "calendar")
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(message)
                .font(.callout)
                .lineLimit(2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
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
