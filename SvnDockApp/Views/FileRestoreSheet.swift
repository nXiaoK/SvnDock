import SwiftUI

struct FileRestorePresentationModifier: ViewModifier {
    @ObservedObject var store: SvnDockStore

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $store.isPresentingFileRestore) {
                if let request = store.pendingFileRestore {
                    FileRestoreSheet(store: store, request: request).id(request.id)
                }
            }
            .onChange(of: store.isPresentingFileRestore) {
                if !store.isPresentingFileRestore {
                    store.cancelFileRestore()
                    Task { await store.processPendingFinderCommands() }
                }
            }
    }
}

private struct FileRestoreSheet: View {
    @ObservedObject var store: SvnDockStore
    let request: SvnDockFileRestoreRequest
    @State private var revisionInput = ""
    @State private var plan: SvnDockFileRestorePlan?
    @State private var error: String?
    @State private var isLoading = false
    @State private var previewTask: Task<Void, Never>?
    @FocusState private var isRevisionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("还原至指定版本前").font(.title2.bold())
            Text(request.entry.relativePath).font(.headline).textSelection(.enabled)
            Text("工作副本：\(request.workingCopy.name)").foregroundStyle(.secondary)
            HStack {
                Text("指定版本")
                TextField("例如 r100 或 100", text: $revisionInput)
                    .textFieldStyle(.roundedBorder).focused($isRevisionFocused)
                    .disabled(isLoading)
                    .onSubmit { preview() }
                Button("预览还原") { preview() }
                    .disabled(isLoading || SvnDockFileRestorePlan.parseRevision(revisionInput) == nil)
            }
            if let revision = SvnDockFileRestorePlan.parseRevision(revisionInput) {
                Text("还原至 r\(revision) 提交之前，即 r\(revision - 1) 的状态。")
            }
            Text("文件内容和 SVN 属性将恢复为历史状态，形成待提交的本地变更。仓库不会自动提交；有未提交修改的文件需先提交或另行保存。")
                .font(.callout).foregroundStyle(.secondary)
            if isLoading { ProgressView("正在检查文件和历史版本…") }
            if let plan {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("当前工作版本 r\(plan.baseRevision) → 目标 r\(plan.targetRevision)").bold()
                        Text("已确认目标文件存在。还原后可查看差异并提交；也可使用普通“还原”放弃此次本地变更。")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("取消") { previewTask?.cancel(); store.cancelFileRestore() }
                    .keyboardShortcut(.cancelAction)
                Button(plan.map { "还原至 r\($0.targetRevision)" } ?? "确认还原") {
                    if let plan { store.confirmFileRestore(plan, requestID: request.id) }
                }
                .disabled(plan == nil || isLoading)
            }
        }
        .padding(24).frame(width: 540)
        .onAppear { isRevisionFocused = true }
        .onChange(of: revisionInput) { plan = nil; error = nil }
        .onDisappear { previewTask?.cancel() }
    }

    private func preview() {
        guard !isLoading, let revision = SvnDockFileRestorePlan.parseRevision(revisionInput) else { return }
        plan = nil
        error = nil
        isLoading = true
        previewTask = Task {
            defer { isLoading = false }
            do { plan = try await store.prepareFileRestore(requestID: request.id, beforeRevision: revision) }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
