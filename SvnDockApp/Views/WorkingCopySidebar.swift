import AppKit
import SwiftUI

struct WorkingCopySidebar: View {
    @ObservedObject var store: SvnDockStore

    var body: some View {
        VStack(spacing: 0) {
            if store.workingCopies.isEmpty {
                SvnDockEmptyState(
                    symbol: "externaldrive.badge.plus",
                    title: "还没有工作副本",
                    message: "添加任意数量的本地 SVN 工作副本。",
                    actionTitle: "添加工作副本"
                ) {
                    store.requestDirectoryImport()
                }
            } else {
                List(selection: $store.selectedWorkingCopyID) {
                    Section("工作副本") {
                        ForEach(store.workingCopies) { workingCopy in
                            WorkingCopyRow(workingCopy: workingCopy)
                                .tag(workingCopy.id)
                                .contextMenu {
                                    Button("查看提交历史…") {
                                        Task { await store.showHistory(for: workingCopy) }
                                    }
                                    Button("更新") {
                                        Task {
                                            await store.update(workingCopyIDs: [workingCopy.id])
                                        }
                                    }
                                    Button("在 Finder 中显示") {
                                        reveal(workingCopy.rootURL)
                                    }
                                    Divider()
                                    Button("停止管理", role: .destructive) {
                                        store.requestRemoval(of: workingCopy)
                                    }
                                }
                        }
                    }
                }
                .listStyle(.sidebar)
                .disabled(store.isInteractionBlocked)
            }

            Divider()

            HStack(spacing: 4) {
                Button {
                    store.requestDirectoryImport()
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(store.isInteractionBlocked)
                .help("添加 SVN 工作副本")

                Button {
                    store.requestRemoval()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(store.selectedWorkingCopy == nil || store.isInteractionBlocked)
                .help("停止管理所选工作副本（不会删除磁盘文件）")

                Spacer()

                Menu {
                    Button("更新全部工作副本") {
                        Task {
                            await store.update(workingCopyIDs: Set(store.workingCopies.map(\.id)))
                        }
                    }
                    .disabled(store.workingCopies.isEmpty || store.isInteractionBlocked)

                    Button("查看所选工作副本历史…") {
                        store.selectedEntryIDs = []
                        Task { await store.showHistoryForSelection() }
                    }
                    .disabled(store.selectedWorkingCopy == nil || store.isInteractionBlocked)

                    Button("清理所选工作副本…") {
                        Task { await store.cleanupSelectedWorkingCopy() }
                    }
                    .disabled(store.selectedWorkingCopy == nil || store.isInteractionBlocked)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .frame(height: 34)
        }
        .navigationTitle("SvnDock")
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct WorkingCopyRow: View {
    let workingCopy: SvnDockWorkingCopy

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(workingCopy.counts.conflicts > 0 ? Color.orange : Color.accentColor)
                .font(.body)

            VStack(alignment: .leading, spacing: 2) {
                Text(workingCopy.name)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let revision = workingCopy.revision {
                        Text("r\(revision)")
                    }
                    Text(workingCopy.rootURL.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            HStack(spacing: 3) {
                SvnDockCountBadge(value: workingCopy.counts.conflicts, tint: .orange)
                SvnDockCountBadge(value: workingCopy.counts.changed, tint: .blue)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
