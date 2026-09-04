import SwiftUI
import UniformTypeIdentifiers

struct SvnDockRootView: View {
    @ObservedObject var store: SvnDockStore

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WorkingCopySidebar(store: store)
            .navigationSplitViewColumnWidth(min: 190, ideal: 235, max: 320)
        } content: {
            StatusListView(store: store)
            .navigationSplitViewColumnWidth(min: 300, ideal: 410, max: 620)
        } detail: {
            InspectorView(store: store)
                .navigationSplitViewColumnWidth(min: 340, ideal: 520)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 980, minHeight: 620)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let operation = store.activeOperation {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text(operation.detail ?? operation.kind.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .help(operation.kind.displayName)
                }

                Button {
                    Task { await store.showHistoryForSelection() }
                } label: {
                    Label("历史", systemImage: "clock.arrow.circlepath")
                }
                .disabled(
                    store.selectedWorkingCopy == nil
                        || store.selectedEntryIDs.count > 1
                        || store.isInteractionBlocked
                )
                .help("查看工作副本或所选项目的提交历史")

                Button {
                    Task { await store.updateSelectedWorkingCopy() }
                } label: {
                    Label("更新", systemImage: "arrow.down.circle")
                }
                .disabled(store.selectedWorkingCopy == nil || store.isInteractionBlocked)
                .help("从仓库更新所选工作副本")

                Button {
                    store.requestCommit()
                } label: {
                    Label("提交", systemImage: "arrow.up.circle")
                }
                .disabled(!store.hasPendingChanges || store.isInteractionBlocked)
                .help("提交所选工作副本中的本地变更")
            }
        }
        .task {
            await store.load()
            await store.processPendingFinderCommands()
        }
        .onOpenURL { url in
            Task { await store.handleFinderURL(url) }
        }
        .onChange(of: store.selectedWorkingCopyID) {
            Task { await store.selectedWorkingCopyDidChange() }
        }
        .onChange(of: store.isPresentingCommit) {
            if !store.isPresentingCommit {
                store.commitPresentationDidDismiss()
                resumeFinderQueueAfterPresentation()
            }
        }
        .onChange(of: store.isPresentingRevertConfirmation) {
            if !store.isPresentingRevertConfirmation {
                store.cancelRevertConfirmation()
                resumeFinderQueueAfterPresentation()
            }
        }
        .onChange(of: store.isPresentingRemovalConfirmation) {
            if !store.isPresentingRemovalConfirmation {
                resumeFinderQueueAfterPresentation()
            }
        }
        .onChange(of: store.isPresentingResolveConfirmation) {
            if !store.isPresentingResolveConfirmation {
                store.cancelResolveConfirmation()
                resumeFinderQueueAfterPresentation()
            }
        }
        .onChange(of: store.isPresentingIgnoreConfirmation) {
            if !store.isPresentingIgnoreConfirmation {
                store.cancelIgnoreConfirmation()
                resumeFinderQueueAfterPresentation()
            }
        }
        .onChange(of: store.isPresentingDirectoryImporter) {
            if !store.isPresentingDirectoryImporter {
                resumeFinderQueueAfterPresentation()
            }
        }
        .onChange(of: store.presentedError) {
            if store.presentedError == nil {
                resumeFinderQueueAfterPresentation()
            }
        }
        .fileImporter(
            isPresented: $store.isPresentingDirectoryImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await store.registerWorkingCopies(at: urls) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    store.presentedError = SvnDockUserFacingError(
                        title: "无法选择目录",
                        message: error.localizedDescription
                    )
                }
            }
        }
        .sheet(isPresented: $store.isPresentingCommit) {
            CommitSheet(store: store)
        }
        .alert(item: $store.presentedError) { error in
            if store.finderQueueRecoveryNeedsRetry {
                Alert(
                    title: Text(error.title),
                    message: Text(error.message),
                    primaryButton: .default(Text("重试")) {
                        Task { await store.retryFinderQueueRecovery() }
                    },
                    secondaryButton: .cancel(Text("稍后"))
                )
            } else {
                Alert(
                    title: Text(error.title),
                    message: Text(error.message),
                    dismissButton: .default(Text("好"))
                )
            }
        }
        .alert("停止管理工作副本？", isPresented: $store.isPresentingRemovalConfirmation) {
            Button("取消", role: .cancel) {
                store.cancelRemoval()
            }
            Button("停止管理", role: .destructive) {
                store.confirmRemoval()
            }
        } message: {
            Text("SvnDock 将从侧栏移除“\(store.pendingRemovalName)”，但不会删除磁盘上的任何文件。")
        }
        .alert("还原所选更改？", isPresented: $store.isPresentingRevertConfirmation) {
            Button("取消", role: .cancel) {
                store.cancelRevertConfirmation()
            }
            Button("还原", role: .destructive) {
                store.confirmRevert()
            }
        } message: {
            Text("此操作会丢弃所选文件尚未提交的本地修改，且无法由 SvnDock 撤销。")
        }
        .confirmationDialog(
            "解决“\(store.pendingResolveName)”的冲突？",
            isPresented: $store.isPresentingResolveConfirmation,
            titleVisibility: .visible
        ) {
            Button(SvnDockConflictResolution.working.displayName) {
                store.confirmResolve(using: .working)
            }
            if store.pendingResolveAllowsReplacement {
                Button(SvnDockConflictResolution.mineFull.displayName, role: .destructive) {
                    store.confirmResolve(using: .mineFull)
                }
                Button(SvnDockConflictResolution.theirsFull.displayName, role: .destructive) {
                    store.confirmResolve(using: .theirsFull)
                }
                Button(SvnDockConflictResolution.base.displayName, role: .destructive) {
                    store.confirmResolve(using: .base)
                }
            }
            Button("取消", role: .cancel) {
                store.cancelResolveConfirmation()
            }
        } message: {
            Text(
                store.pendingResolveAllowsReplacement
                    ? "除“保留当前内容”外，其余选项会替换当前文件内容，且无法由 SvnDock 撤销。"
                    : "属性或树冲突只能保留当前工作状态并标记为已解决。"
            )
        }
        .alert("添加 SVN 忽略规则？", isPresented: $store.isPresentingIgnoreConfirmation) {
            Button("取消", role: .cancel) {
                store.cancelIgnoreConfirmation()
            }
            Button("添加规则") {
                store.confirmIgnore()
            }
        } message: {
            Text(store.pendingIgnoreMessage)
        }
    }

    private func resumeFinderQueueAfterPresentation() {
        Task {
            await store.processPendingFinderCommands()
        }
    }
}

#if DEBUG && !SWIFT_PACKAGE
#Preview("Main Window") {
    SvnDockRootView(
        store: SvnDockStore(service: MockSvnDockService.preview())
    )
}
#endif
