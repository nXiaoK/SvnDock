import SwiftUI
import UniformTypeIdentifiers

struct SvnDockRootView: View {
    @ObservedObject var store: SvnDockStore

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            commandBar
            Divider().overlay(SvnDockTheme.border)
            HSplitView {
                WorkingCopySidebar(store: store)
                    .frame(minWidth: 200, idealWidth: 232, maxWidth: 260)
                VStack(spacing: 0) {
                    workingCopyHeader
                    Divider().overlay(SvnDockTheme.border)
                    HSplitView {
                        StatusListView(store: store)
                            .frame(minWidth: 300, idealWidth: 348, maxWidth: 400)
                        InspectorView(store: store)
                            .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 760, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(SvnDockTheme.surface)
        .foregroundStyle(SvnDockTheme.text)
        .tint(SvnDockTheme.accent)
        .frame(minWidth: 1080, minHeight: 680)
        .task {
            await store.load()
            await store.processPendingFinderCommands()
        }
        .onOpenURL { url in
            Task { await store.handleFinderURL(url) }
        }
        .onChange(of: store.selectedWorkingCopyID) {
            let selectedID = store.selectedWorkingCopyID
            Task { await store.selectedWorkingCopyDidChange(to: selectedID) }
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
        .modifier(UnscheduleAddPresentationModifier(store: store))
    }

    private var commandBar: some View {
        HStack(spacing: 24) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(SvnDockTheme.accent.gradient)
                VStack(alignment: .leading, spacing: 3) {
                    Text("SvnDock")
                        .font(.system(size: 19, weight: .semibold))
                    Text("简单、从容地管理每一次变更")
                        .font(.system(size: 11))
                        .foregroundStyle(SvnDockTheme.secondaryText)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 12) {
                command("更新", symbol: "arrow.triangle.2.circlepath",
                        disabled: store.selectedWorkingCopy == nil || store.isInteractionBlocked) {
                    Task { await store.updateSelectedWorkingCopy() }
                }
                command("提交", symbol: "icloud.and.arrow.up",
                        disabled: !store.hasPendingChanges || store.isInteractionBlocked) {
                    store.requestCommit()
                }
                command("历史", symbol: "clock",
                        disabled: store.selectedWorkingCopy == nil || store.selectedEntryIDs.count > 1 || store.isInteractionBlocked) {
                    Task { await store.showHistoryForSelection() }
                }
                Menu {
                    Button("刷新工作副本状态") {
                        Task { await store.reloadSelectedWorkingCopy() }
                    }
                    .disabled(store.selectedWorkingCopy == nil || store.isInteractionBlocked)
                    Button("清理工作副本…") {
                        Task { await store.cleanupSelectedWorkingCopy() }
                    }
                    .disabled(store.selectedWorkingCopy == nil || store.isInteractionBlocked)
                    Divider()
                    Button("添加工作副本…") { store.requestDirectoryImport() }
                        .disabled(store.isInteractionBlocked)
                } label: {
                    commandLabel("更多", symbol: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(SvnDockPlainButtonStyle())
                .menuIndicator(.hidden)
                .fixedSize()
            }
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                TextField("搜索文件或路径…", text: $store.searchQuery)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .accessibilityLabel("搜索文件或路径")
                if !store.searchQuery.isEmpty {
                    Button {
                        store.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SvnDockPlainButtonStyle())
                    .accessibilityLabel("清除搜索")
                }
                Button {
                    isSearchFocused = true
                } label: {
                    Text("⌘ K")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 6)
                        .frame(minWidth: 38, minHeight: 32)
                        .contentShape(Rectangle())
                        .background(SvnDockTheme.subtleSurface, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(SvnDockPlainButtonStyle(cornerRadius: 4))
                .keyboardShortcut("k", modifiers: .command)
                .accessibilityLabel("聚焦搜索")
            }
            .foregroundStyle(SvnDockTheme.secondaryText)
            .padding(.horizontal, 12)
            .frame(minWidth: 230, idealWidth: 330, maxWidth: 390)
            .frame(height: 38)
            .svnDockSurface(cornerRadius: 12)
        }
        .padding(.horizontal, 22)
        .frame(height: 74)
        .background(LinearGradient(
            colors: [SvnDockTheme.sidebar.opacity(0.8), SvnDockTheme.subtleSurface],
            startPoint: .leading, endPoint: .trailing
        ))
    }

    private func command(_ title: String, symbol: String, disabled: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) { commandLabel(title, symbol: symbol) }
            .buttonStyle(SvnDockPlainButtonStyle())
            .disabled(disabled)
            .help(title)
    }

    private func commandLabel(_ title: String, symbol: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .frame(height: 23)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(SvnDockTheme.secondaryText)
        }
        .frame(width: 48, height: 54)
        .contentShape(Rectangle())
    }

    private var workingCopyHeader: some View {
        HStack(spacing: 16) {
            SvnDockFolderIcon(size: 31)
            VStack(alignment: .leading, spacing: 5) {
                Text(store.selectedWorkingCopy?.name ?? "选择工作副本")
                    .font(.system(size: 19, weight: .semibold))
                Text(store.selectedWorkingCopy?.rootURL.path(percentEncoded: false) ?? "添加本地 SVN 目录，开始管理变更")
                    .font(.system(size: 12))
                    .foregroundStyle(SvnDockTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            if let copy = store.selectedWorkingCopy {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        revisionLabel(copy)
                        if let refreshedAt = copy.lastRefreshedAt {
                            Text("最近刷新  \(refreshedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 11))
                                .foregroundStyle(SvnDockTheme.secondaryText)
                        }
                    }
                    revisionLabel(copy)
                }
                Divider().frame(height: 32)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        if store.isBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Circle()
                                .fill(copy.counts.conflicts > 0 ? SvnDockTheme.red : SvnDockTheme.green)
                                .frame(width: 9, height: 9)
                        }
                        Text(store.activeOperation?.kind.displayName
                             ?? (copy.counts.conflicts > 0 ? "存在待解决冲突" : "工作副本已载入"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    Text(copy.counts.conflicts > 0
                         ? "\(copy.counts.conflicts) 个文件存在冲突"
                         : "\(copy.counts.changed) 个文件发生变更")
                        .font(.system(size: 11))
                        .foregroundStyle(SvnDockTheme.secondaryText)
                        .padding(.leading, 17)
                }
                .fixedSize()
            } else if let operation = store.activeOperation {
                ProgressView().controlSize(.small)
                Text(operation.detail ?? operation.kind.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(SvnDockTheme.secondaryText)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 78)
        .background(SvnDockTheme.subtleSurface.opacity(0.5))
    }

    private func revisionLabel(_ copy: SvnDockWorkingCopy) -> some View {
        HStack(spacing: 7) {
            Text("当前版本").foregroundStyle(SvnDockTheme.secondaryText)
            Text(verbatim: copy.revision.map { "r\($0)" } ?? "—")
                .foregroundStyle(SvnDockTheme.accent)
                .fontWeight(.semibold)
        }
        .font(.system(size: 12))
        .fixedSize()
    }

    private func resumeFinderQueueAfterPresentation() {
        Task {
            await store.processPendingFinderCommands()
        }
    }
}

private struct UnscheduleAddPresentationModifier: ViewModifier {
    @ObservedObject var store: SvnDockStore

    func body(content: Content) -> some View {
        content
            .onChange(of: store.isPresentingUnscheduleAddConfirmation) {
                if !store.isPresentingUnscheduleAddConfirmation {
                    store.cancelUnscheduleAddConfirmation()
                    Task { await store.processPendingFinderCommands() }
                }
            }
            .alert(
                store.isConfirmingMissingAdditionCleanup ? "清理缺失的添加记录？" : "取消添加所选项目？",
                isPresented: $store.isPresentingUnscheduleAddConfirmation
            ) {
                Button("取消", role: .cancel) {
                    store.cancelUnscheduleAddConfirmation()
                }
                Button(store.isConfirmingMissingAdditionCleanup ? "清理记录" : "取消添加") {
                    store.confirmUnscheduleAdd()
                }
            } message: {
                Text(store.unscheduleAddConfirmationMessage)
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
