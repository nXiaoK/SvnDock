import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SvnDockRootView: View {
    @ObservedObject var store: SvnDockStore

    @FocusState private var isSearchFocused: Bool
    @State private var isRemoteStatusPresented = false

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
            Divider().overlay(SvnDockTheme.border)
            OperationRecordBar(store: store)
        }
        .background(SvnDockTheme.surface)
        .foregroundStyle(SvnDockTheme.text)
        .tint(SvnDockTheme.accent)
        .frame(minWidth: 1080, minHeight: 680)
        .task {
            await store.startIfNeeded()
        }
        .onOpenURL { url in
            Task { await store.handleFinderURL(url) }
        }
        .onChange(of: store.selectedWorkingCopyID) {
            isRemoteStatusPresented = false
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
            Text(store.revertConfirmationMessage)
        }
        .sheet(isPresented: $store.isPresentingResolveConfirmation) {
            if let review = store.pendingConflictReview {
                ConflictReviewSheet(store: store, review: review)
                    .id(review.id)
            }
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
        .modifier(MissingDeletionPresentationModifier(store: store))
    }

    private var commandBar: some View {
        HStack(spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(SvnDockTheme.accent.gradient)
                VStack(alignment: .leading, spacing: 3) {
                    Text("SvnDock")
                        .font(.system(size: 19, weight: .semibold))
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                command("刷新本地", symbol: "arrow.clockwise",
                        disabled: store.selectedWorkingCopy == nil || store.isInteractionBlocked) {
                    Task { await store.reloadSelectedWorkingCopy() }
                }
                command("检查服务器", symbol: "network",
                        disabled: store.selectedWorkingCopy == nil || store.isInteractionBlocked
                            || store.selectedRemoteStatus.isChecking) {
                    isRemoteStatusPresented = true
                    Task { await store.checkSelectedRemoteStatus() }
                }
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
        .frame(height: 66)
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
        .frame(width: title.count > 4 ? 68 : 48, height: 54)
        .contentShape(Rectangle())
    }

    private var workingCopyHeader: some View {
        HStack(spacing: 16) {
            SvnDockFolderIcon(size: 31)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text(store.selectedWorkingCopy?.name ?? "选择工作副本")
                        .font(.system(size: 19, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let copy = store.selectedWorkingCopy {
                        revisionLabel(copy)
                    }
                }
                if let copy = store.selectedWorkingCopy {
                    identityLine(copy.repositoryURL?.absoluteString ?? "仓库地址尚未读取",
                                 symbol: "network", copyLabel: "复制仓库地址",
                                 canCopy: copy.repositoryURL != nil)
                    identityLine(copy.rootURL.path(percentEncoded: false),
                                 symbol: "folder", copyLabel: "复制本地路径")
                } else {
                    Text("添加本地 SVN 目录，开始管理变更")
                        .font(.system(size: 12))
                        .foregroundStyle(SvnDockTheme.secondaryText)
                }
            }
            Spacer(minLength: 12)
            if let copy = store.selectedWorkingCopy {
                Divider().frame(height: 54)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if store.isBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: copy.counts.conflicts > 0 ? "exclamationmark.triangle" : "internaldrive")
                                .foregroundStyle(copy.counts.conflicts > 0 ? SvnDockTheme.red : SvnDockTheme.secondaryText)
                        }
                        Text(copy.localStatusSummary)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .help(copy.localStatusDetail)
                    remoteStatusButton
                    if let operation = store.activeOperation {
                        Text(operation.kind.displayName)
                            .font(.system(size: 10))
                            .foregroundStyle(SvnDockTheme.secondaryText)
                    } else if let refreshedAt = copy.lastRefreshedAt {
                        Text("本地刷新 \(refreshedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 10))
                            .foregroundStyle(SvnDockTheme.secondaryText)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            } else if let operation = store.activeOperation {
                ProgressView().controlSize(.small)
                Text(operation.detail ?? operation.kind.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(SvnDockTheme.secondaryText)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 98)
        .background(SvnDockTheme.subtleSurface.opacity(0.5))
    }

    private func revisionLabel(_ copy: SvnDockWorkingCopy) -> some View {
        HStack(spacing: 7) {
            Text("根目录基线").foregroundStyle(SvnDockTheme.secondaryText)
            Text(verbatim: copy.revision.map { "r\($0)" } ?? "—")
                .foregroundStyle(SvnDockTheme.accent)
                .fontWeight(.semibold)
        }
        .font(.system(size: 12))
        .fixedSize()
        .help("这是工作副本根目录的基线修订号；子目录和文件可能处于不同修订。")
    }

    private func identityLine(_ value: String, symbol: String, copyLabel: String,
                              canCopy: Bool = true) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).frame(width: 13)
            Text(verbatim: value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.system(size: 11))
        .foregroundStyle(SvnDockTheme.secondaryText)
        .help(value)
        .contextMenu {
            Button(copyLabel) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
            .disabled(!canCopy)
        }
    }

    private var remoteStatusButton: some View {
        Button {
            isRemoteStatusPresented = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: store.selectedRemoteStatus.lastError == nil ? "network" : "exclamationmark.triangle")
                Text(store.selectedRemoteStatus.summary)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11))
            .foregroundStyle(SvnDockTheme.accent)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(SvnDockPlainButtonStyle())
        .help("查看服务器检查时间与受影响路径；本地刷新不会检查服务器。")
        .popover(isPresented: $isRemoteStatusPresented, arrowEdge: .bottom) {
            RemoteStatusPopover(store: store)
        }
    }

    private func resumeFinderQueueAfterPresentation() {
        Task {
            await store.processPendingFinderCommands()
        }
    }
}

private struct MissingDeletionPresentationModifier: ViewModifier {
    @ObservedObject var store: SvnDockStore

    func body(content: Content) -> some View {
        content
            .onChange(of: store.isPresentingMissingDeletionConfirmation) {
                if !store.isPresentingMissingDeletionConfirmation {
                    store.cancelMissingDeletionConfirmation()
                    Task { await store.processPendingFinderCommands() }
                }
            }
            .alert("标记为 SVN 删除？", isPresented: $store.isPresentingMissingDeletionConfirmation) {
                Button("取消", role: .cancel) {
                    store.cancelMissingDeletionConfirmation()
                }
                Button("标记删除", role: .destructive) {
                    store.confirmMissingDeletion()
                }
            } message: {
                Text(store.missingDeletionConfirmationMessage)
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
