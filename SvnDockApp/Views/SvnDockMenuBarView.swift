import AppKit
import SwiftUI

@MainActor
struct SvnDockMenuBarView: View {
    @ObservedObject var store: SvnDockStore
    let showMainWindow: () -> Void

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("打开 SvnDock", systemImage: "macwindow", action: showMainWindow)

        Divider()

        if let workingCopy = store.selectedWorkingCopy {
            Text("当前工作副本：\(workingCopy.name)")
            Text(workingCopy.lastRefreshedAt == nil
                 ? "状态：未刷新"
                 : "上次状态：\(statusSummary(for: workingCopy))")
        } else {
            Text("尚未选择工作副本")
        }

        if let operation = store.activeOperation {
            Text(operation.kind.displayName)
        } else if store.isBusy {
            Text("正在处理操作…")
        }

        if let error = store.presentedError {
            Button("查看错误：\(error.title)", systemImage: "exclamationmark.triangle",
                   action: showMainWindow)
        }

        if !store.workingCopies.isEmpty {
            Menu("工作副本", systemImage: "externaldrive") {
                ForEach(store.workingCopies) { workingCopy in
                    Button {
                        guard !store.isSidebarNavigationBlocked else { return }
                        showMainWindow()
                        Task { await store.selectWorkingCopyFromMenu(workingCopy.id) }
                    } label: {
                        Label(
                            "\(workingCopy.name) · \(statusSummary(for: workingCopy))",
                            systemImage: store.selectedWorkingCopyID == workingCopy.id
                                ? "checkmark" : "externaldrive"
                        )
                    }
                    .help(workingCopy.rootURL.path(percentEncoded: false))
                }
            }
            .disabled(store.isSidebarNavigationBlocked)
        }

        Divider()

        Button("刷新状态", systemImage: "arrow.clockwise") {
            guard canOperateOnWorkingCopy else { return }
            showMainWindow()
            Task { await store.reloadSelectedWorkingCopy() }
        }
        .disabled(!canOperateOnWorkingCopy)

        Button("更新当前工作副本", systemImage: "arrow.triangle.2.circlepath") {
            guard canOperateOnWorkingCopy, let workingCopy = store.selectedWorkingCopy else { return }
            showMainWindow()
            Task { await store.update(workingCopyIDs: [workingCopy.id]) }
        }
        .disabled(!canOperateOnWorkingCopy)

        Button("提交…", systemImage: "icloud.and.arrow.up") {
            guard canOperateOnWorkingCopy, store.hasPendingChanges else { return }
            showMainWindow()
            store.requestCommit()
        }
        .disabled(!canOperateOnWorkingCopy || !store.hasPendingChanges)

        Button("查看提交历史", systemImage: "clock") {
            guard canOperateOnWorkingCopy, let workingCopy = store.selectedWorkingCopy else { return }
            showMainWindow()
            Task { await store.showHistory(for: workingCopy) }
        }
        .disabled(!canOperateOnWorkingCopy)

        Button("在 Finder 中显示", systemImage: "folder") {
            guard let workingCopy = store.selectedWorkingCopy else { return }
            NSWorkspace.shared.activateFileViewerSelecting([workingCopy.rootURL])
        }
        .disabled(store.selectedWorkingCopy == nil)

        Divider()

        Button("添加工作副本…", systemImage: "plus") {
            guard !store.isInteractionBlocked else { return }
            showMainWindow()
            store.requestDirectoryImport()
        }
        .disabled(store.isInteractionBlocked)

        Button("设置…", systemImage: "gearshape") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("退出 SvnDock") {
            NSApp.terminate(nil)
        }
    }

    private var canOperateOnWorkingCopy: Bool {
        store.selectedWorkingCopy != nil && !store.isInteractionBlocked
    }

    private func statusSummary(for workingCopy: SvnDockWorkingCopy) -> String {
        guard workingCopy.lastRefreshedAt != nil else { return "未刷新" }
        let counts = workingCopy.counts
        var parts: [String] = []
        if counts.changed > 0 { parts.append("\(counts.changed) 个变更") }
        if counts.conflicts > 0 { parts.append("\(counts.conflicts) 个冲突") }
        if counts.unversioned > 0 { parts.append("\(counts.unversioned) 个未纳管") }
        return parts.isEmpty ? "工作副本干净" : parts.joined(separator: "，")
    }
}
