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
            } else if store.filteredEntries.isEmpty && !store.isBusy {
                SvnDockEmptyState(
                    symbol: "line.3.horizontal.decrease.circle",
                    title: "没有匹配项目",
                    message: "调整筛选条件或搜索文字后重试。"
                )
            } else {
                List(store.filteredEntries, selection: $store.selectedEntryIDs) { entry in
                    StatusEntryRow(entry: entry)
                        .tag(entry.id)
                        .contextMenu {
                            entryContextMenu(for: entry)
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
            Text("\(store.filteredEntries.count) 项")
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

    @ViewBuilder
    private func entryContextMenu(for entry: SvnDockStatusEntry) -> some View {
        if entry.status == .unversioned {
            Button("添加到 SVN") {
                store.selectedEntryIDs = [entry.id]
                Task { await store.addSelectedUnversionedEntries() }
            }

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
            Button("查看差异") {
                store.selectedEntryIDs = [entry.id]
                store.inspectorTab = .diff
            }
            Button("还原…", role: .destructive) {
                store.selectedEntryIDs = [entry.id]
                store.requestRevertConfirmation()
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
            reveal(entry)
        }
        Button("复制相对路径") {
            copy(entry.relativePath)
        }
    }

    private func reveal(_ entry: SvnDockStatusEntry) {
        guard let root = store.selectedWorkingCopy?.rootURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root.appending(path: entry.relativePath)])
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
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
