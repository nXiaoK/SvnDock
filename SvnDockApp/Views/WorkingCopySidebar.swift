import AppKit
import SwiftUI

struct WorkingCopySidebar: View {
    @ObservedObject var store: SvnDockStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("代码仓库")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    store.requestDirectoryImport()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                        .svnDockSurface(cornerRadius: 7)
                }
                .buttonStyle(SvnDockPlainButtonStyle(cornerRadius: 7))
                .disabled(store.isInteractionBlocked)
                .help("添加 SVN 工作副本")
                .accessibilityLabel("添加工作副本")
            }
            .foregroundStyle(SvnDockTheme.secondaryText)
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 10)

            if store.workingCopies.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("让版本管理井井有条")
                        .font(.system(size: 14, weight: .medium))
                    Text("添加本地 SVN 工作副本，即可在这里查看文件和变更。")
                        .font(.system(size: 12))
                        .foregroundStyle(SvnDockTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                Spacer()
            } else {
                List(selection: $store.selectedWorkingCopyID) {
                    ForEach(store.workingCopies) { workingCopy in
                        WorkingCopyRow(
                            workingCopy: workingCopy,
                            isSelected: store.selectedWorkingCopyID == workingCopy.id
                        )
                        .svnDockCardSelection()
                        .tag(workingCopy.id)
                        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            Button("查看提交历史…") {
                                Task { await store.showHistory(for: workingCopy) }
                            }
                            Button("更新") {
                                Task { await store.update(workingCopyIDs: [workingCopy.id]) }
                            }
                            Button("在 Finder 中显示") {
                                NSWorkspace.shared.activateFileViewerSelecting([workingCopy.rootURL])
                            }
                            Divider()
                            Button("停止管理", role: .destructive) {
                                store.requestRemoval(of: workingCopy)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .disabled(store.isSidebarNavigationBlocked)
            }

            VStack(spacing: 4) {
                Divider().overlay(SvnDockTheme.border).padding(.bottom, 8)
                Button {
                    store.requestDirectoryImport()
                } label: {
                    sidebarAction("添加仓库", symbol: "plus.circle")
                }
                .disabled(store.isInteractionBlocked)

                SettingsLink {
                    sidebarAction("设置", symbol: "gearshape")
                }

                Menu {
                    Button("更新全部工作副本") {
                        Task { await store.update(workingCopyIDs: Set(store.workingCopies.map(\.id))) }
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
                    Divider()
                    Button("停止管理所选工作副本…", role: .destructive) {
                        store.requestRemoval()
                    }
                    .disabled(store.selectedWorkingCopy == nil || store.isInteractionBlocked)
                } label: {
                    sidebarAction("仓库操作", symbol: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(SvnDockPlainButtonStyle())
                .menuIndicator(.hidden)
            }
            .buttonStyle(SvnDockPlainButtonStyle())
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(maxHeight: .infinity)
        .background(LinearGradient(
            colors: [SvnDockTheme.sidebar, SvnDockTheme.sidebar.opacity(0.8)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ))
    }

    private func sidebarAction(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .frame(width: 20)
            Text(title).font(.system(size: 12))
            Spacer()
        }
        .foregroundStyle(SvnDockTheme.text.opacity(0.85))
        .padding(.horizontal, 8)
        .frame(height: 34)
        .contentShape(Rectangle())
    }
}

private struct WorkingCopyRow: View {
    let workingCopy: SvnDockWorkingCopy
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            SvnDockFolderIcon(size: 26)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(workingCopy.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SvnDockTheme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if workingCopy.counts.changed > 0 || workingCopy.counts.conflicts > 0 {
                        Text("\(workingCopy.counts.conflicts > 0 ? workingCopy.counts.conflicts : workingCopy.counts.changed)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(SvnDockTheme.onAccent)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(workingCopy.counts.conflicts > 0 ? SvnDockTheme.red : SvnDockTheme.accent,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .help("\(workingCopy.counts.changed) 个变更，\(workingCopy.counts.conflicts) 个冲突")
                            .accessibilityLabel("\(workingCopy.counts.changed) 个变更，\(workingCopy.counts.conflicts) 个冲突")
                    }
                }
                Text(workingCopy.rootURL.path(percentEncoded: false))
                    .font(.system(size: 11))
                    .foregroundStyle(SvnDockTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(12)
        .frame(minHeight: 66)
        .background(isSelected ? SvnDockTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? SvnDockTheme.accent.opacity(0.16) : .clear)
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}
