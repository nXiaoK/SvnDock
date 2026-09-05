import AppKit
import Foundation
import SvnDockCore
import SwiftUI

@MainActor
final class SvnDockStore: ObservableObject {
    private static let initialVisibleEntryLimit = 500
    private static let visibleEntryBatchSize = 500
    private static let initialDirectoryChildLimit = 250
    private static let directoryChildBatchSize = 250

    private static let finderHandoffNotification = Notification.Name(
        "com.svndock.command-handoff"
    )

    @Published private(set) var workingCopies: [SvnDockWorkingCopy] = []
    @Published var selectedWorkingCopyID: UUID? {
        didSet {
            if oldValue != selectedWorkingCopyID { clearDiff() }
        }
    }
    @Published var selectedEntryIDs: Set<SvnDockStatusEntry.ID> = [] {
        didSet {
            if oldValue != selectedEntryIDs { clearDiff() }
        }
    }

    @Published var statusFilter: SvnDockStatusFilter = .all {
        didSet {
            if oldValue != statusFilter { rebuildStatusPresentation(resetLimit: true, debounce: false) }
        }
    }
    @Published var searchQuery = "" {
        didSet {
            if oldValue != searchQuery { rebuildStatusPresentation(resetLimit: true, debounce: true) }
        }
    }
    @Published var showsMissingDetails = false {
        didSet {
            if oldValue != showsMissingDetails { rebuildStatusPresentation(resetLimit: true, debounce: false) }
        }
    }
    @Published private(set) var displayedEntries: [SvnDockStatusEntry] = []
    @Published private(set) var filteredEntryCount = 0
    @Published private(set) var isFilteringStatusEntries = false
    @Published private var expandedDirectoryIDs: Set<SvnDockStatusEntry.ID> = []
    @Published private var directoryChildrenByID: [
        SvnDockStatusEntry.ID: [SvnDockStatusEntry]
    ] = [:]
    @Published private var loadingDirectoryIDs: Set<SvnDockStatusEntry.ID> = []
    @Published private var directoryErrorsByID: [SvnDockStatusEntry.ID: String] = [:]
    @Published private var directoryVisibleLimits: [SvnDockStatusEntry.ID: Int] = [:]
    @Published var inspectorTab: SvnDockInspectorTab = .diff {
        didSet {
            if oldValue == .diff, inspectorTab != .diff { clearDiff() }
            if oldValue == .history, inspectorTab != .history {
                cancelHiddenHistoryLoad()
            }
        }
    }
    @Published private(set) var diffText = ""
    @Published private(set) var diffLoadError: String?
    @Published private(set) var isLoadingDiff = false
    @Published private(set) var historyEntries: [SvnDockLogEntry] = []
    @Published private(set) var historyTarget: SvnDockHistoryTarget?
    @Published private(set) var historyLimit = 100
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var historyErrorMessage: String?

    @Published private(set) var activeOperation: SvnDockOperationState?
    @Published private(set) var operationRecords: [SvnDockOperationRecord] = []
    @Published private var remoteStatusByWorkingCopyID: [UUID: SvnDockRemoteStatusState] = [:]
    private var remoteStatusGeneration: [UUID: UUID] = [:]
    @Published var presentedError: SvnDockUserFacingError?
    @Published var isPresentingCommit = false
    @Published var isPresentingDirectoryImporter = false
    @Published var isPresentingUnscheduleAddConfirmation = false
    @Published var isPresentingMissingDeletionConfirmation = false
    @Published var isPresentingRevertConfirmation = false
    @Published var isPresentingRemovalConfirmation = false
    @Published var isPresentingResolveConfirmation = false
    @Published var isPresentingIgnoreConfirmation = false

    private let service: any SvnDockServicing
    let commitDraftStore: SvnDockCommitDraftStore
    private let finderQueueCoordinator: FinderCommandQueueCoordinator?
    private var finderConsumerLease: FinderCommandConsumerLease?
    private nonisolated(unsafe) var finderHandoffObserver: NSObjectProtocol?
    private var didRecoverFinderClaims = false
    private var isPreparingFinderQueue = false
    private var processingFinderCommandIDs: Set<UUID> = []
    private var finalizingFinderCommandIDs: Set<UUID> = []
    private var rejectedFinderCommandIDs: Set<UUID> = []
    private var suppressedSelectionReloadID: UUID?
    private var startupTask: Task<Void, Never>?
    private var hasStarted = false
    private var pendingUnscheduleAdd: PendingUnscheduleAdd?
    private var pendingMissingDeletion: PendingMissingDeletion?
    private var pendingRevert: PendingRevert?
    private var pendingRemoval: SvnDockWorkingCopy?
    private var pendingResolve: PendingResolve?
    private var pendingIgnore: PendingIgnore?
    private var statusSnapshot = SvnDockStatusSnapshot.empty
    private var filteredStatusEntries: [SvnDockStatusEntry] = []
    private var visibleEntryLimit = SvnDockStore.initialVisibleEntryLimit
    private var statusLoadGeneration = UUID()
    private var activeStatusLoadTask: Task<SvnDockStatusSnapshot, Error>?
    private var statusPresentationGeneration = UUID()
    private var statusPresentationTask: Task<Void, Never>?
    private var discoveredEntryIndex: [SvnDockStatusEntry.ID: SvnDockStatusEntry] = [:]
    private var directoryLoadTasks: [SvnDockStatusEntry.ID: Task<Void, Never>] = [:]
    private var directoryLoadGenerations: [SvnDockStatusEntry.ID: UUID] = [:]
    private var historyLoadGeneration: UUID?
    private var diffLoadGeneration = UUID()
    private var diffLoadTask: Task<String, Error>?
    private var historyLoadTask: Task<Void, Never>?
    private var historyNeedsReload = false
    private var isFinderQueueRecoveryPaused = false
    private var finderQueueRecoveryErrorID: UUID?
    private var isDrainingFinderQueue = false
    private var pendingCommitClaim: FinderCommandClaim?
    @Published private var activeFinderCommandID: UUID?

    init(
        service: any SvnDockServicing,
        finderSharedStore: FinderSharedStore? = nil,
        commitDraftStore: SvnDockCommitDraftStore? = nil
    ) {
        self.service = service
        self.commitDraftStore = commitDraftStore ?? SvnDockCommitDraftStore()
        self.finderQueueCoordinator = finderSharedStore.flatMap {
            try? FinderCommandQueueCoordinator(directoryURL: $0.directoryURL)
        }
        self.finderHandoffObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.finderHandoffNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isFinderQueueRecoveryPaused = false
                await self.processPendingFinderCommands()
            }
        }
    }

    deinit {
        if let finderHandoffObserver {
            DistributedNotificationCenter.default().removeObserver(finderHandoffObserver)
        }
    }

    var selectedWorkingCopy: SvnDockWorkingCopy? {
        workingCopies.first { $0.id == selectedWorkingCopyID }
    }

    var selectedRemoteStatus: SvnDockRemoteStatusState {
        guard let id = selectedWorkingCopyID else { return SvnDockRemoteStatusState() }
        return remoteStatusByWorkingCopyID[id] ?? SvnDockRemoteStatusState()
    }

    func checkSelectedRemoteStatus() async {
        guard !isInteractionBlocked, let copy = selectedWorkingCopy else { return }
        let generation = UUID()
        remoteStatusGeneration[copy.id] = generation
        var state = remoteStatusByWorkingCopyID[copy.id] ?? SvnDockRemoteStatusState()
        state.isChecking = true
        state.lastError = nil
        remoteStatusByWorkingCopyID[copy.id] = state
        activeOperation = SvnDockOperationState(kind: .checkingRemote, detail: copy.name)
        do {
            let snapshot = try await service.checkRemoteStatus(for: copy)
            try Task.checkCancellation()
            guard remoteStatusGeneration[copy.id] == generation,
                  workingCopies.contains(where: { $0.id == copy.id && $0.rootURL == copy.rootURL }) else {
                activeOperation = nil
                return
            }
            state.snapshot = snapshot
            state.isStale = false
        } catch {
            state.isStale = state.snapshot != nil
            state.lastError = error is CancellationError ? "检查已取消。" : error.localizedDescription
        }
        state.isChecking = false
        if remoteStatusGeneration[copy.id] == generation {
            remoteStatusByWorkingCopyID[copy.id] = state
        }
        activeOperation = nil
        await processPendingFinderCommands()
    }

    private func invalidateRemoteStatus(for id: UUID) {
        guard var state = remoteStatusByWorkingCopyID[id] else { return }
        state.isStale = state.snapshot != nil
        remoteStatusByWorkingCopyID[id] = state
    }

    private func recordOperation(_ record: SvnDockOperationRecord) {
        operationRecords = SvnDockOperationRecord.prepending(record, to: operationRecords)
    }

    var entries: [SvnDockStatusEntry] { statusSnapshot.entries }
    var selectedEntries: [SvnDockStatusEntry] { selectedStatusEntries { _ in true } }
    var statusCounts: SvnDockStatusCounts { statusSnapshot.counts }
    var missingEntryCount: Int { statusSnapshot.missingEntries.count }
    var missingAdditionCount: Int { statusSnapshot.missingAdditionCount }
    var missingVersionedCount: Int { statusSnapshot.missingVersionedCount }
    var groupedMissingCount: Int { statusSnapshot.groupedMissingCount }

    var hasMoreFilteredEntries: Bool {
        displayedEntries.count < filteredEntryCount
    }

    var nextVisibleEntryCount: Int {
        min(Self.visibleEntryBatchSize, filteredEntryCount - displayedEntries.count)
    }

    var primarySelectedEntry: SvnDockStatusEntry? {
        guard let id = selectedEntryIDs.min() else { return nil }
        return statusEntry(withID: id)
    }

    var committableEntries: [SvnDockStatusEntry] {
        statusSnapshot.committableEntries
    }

    var hasPendingChanges: Bool {
        !statusSnapshot.committableEntries.isEmpty
    }

    /// Status scans and presentation building are read-only. Keeping the
    /// sidebar navigable during those operations lets users leave a large
    /// working copy while SVN is still walking the disk.
    var isSidebarNavigationBlocked: Bool {
        if hasBlockingPresentation
            || activeFinderCommandID != nil
            || !finalizingFinderCommandIDs.isEmpty {
            return true
        }
        guard let kind = activeOperation?.kind else { return false }
        switch kind {
        case .refreshing, .checkingRemote:
            return false
        case .loading, .updating, .committing, .adding, .unschedulingAdd, .deleting,
             .reverting, .cleaning, .resolving, .ignoring:
            return true
        }
    }

    var isBusy: Bool {
        activeOperation != nil
            || activeFinderCommandID != nil
            || !finalizingFinderCommandIDs.isEmpty
    }

    var isInteractionBlocked: Bool {
        isBusy || hasBlockingPresentation
    }

    var finderQueueRecoveryNeedsRetry: Bool {
        isFinderQueueRecoveryPaused
            && presentedError?.id == finderQueueRecoveryErrorID
    }

    var pendingRemovalName: String {
        pendingRemoval?.name ?? "所选目录"
    }

    var pendingResolveName: String {
        pendingResolve?.displayName ?? "所选项目"
    }

    var pendingResolveAllowsReplacement: Bool {
        pendingResolve?.allowsFileReplacement == true
    }

    var pendingIgnoreMessage: String {
        pendingIgnore?.message
            ?? "该规则会写入父目录的 svn:ignore 属性，并需要提交后才能与团队共享。"
    }

    var canLoadMoreHistory: Bool {
        !isLoadingHistory
            && historyTarget != nil
            && historyEntries.count >= historyLimit
            && historyLimit < 1_000
    }

    private var hasBlockingPresentation: Bool {
        isPresentingCommit
            || isPresentingDirectoryImporter
            || isPresentingUnscheduleAddConfirmation
            || isPresentingMissingDeletionConfirmation
            || isPresentingRevertConfirmation
            || isPresentingRemovalConfirmation
            || isPresentingResolveConfirmation
            || isPresentingIgnoreConfirmation
            || presentedError != nil
    }

    func selectedWorkingCopyDidChange(to expectedID: UUID?) async {
        guard expectedID == selectedWorkingCopyID else {
            if suppressedSelectionReloadID == expectedID {
                suppressedSelectionReloadID = nil
            }
            return
        }
        if let suppressedID = suppressedSelectionReloadID {
            suppressedSelectionReloadID = nil
            if suppressedID == expectedID {
                return
            }
        }
        if historyTarget?.workingCopy.id != selectedWorkingCopyID {
            clearHistory()
        }
        clearStatusEntries()
        selectedEntryIDs = []
        diffText = ""
        await reloadSelectedWorkingCopy()
    }

    /// Menu actions also work when the main window and its selection observer
    /// are absent. Suppress that observer if a window opens during this scan.
    func selectWorkingCopyFromMenu(_ id: UUID) async {
        guard !isSidebarNavigationBlocked,
              workingCopies.contains(where: { $0.id == id }),
              selectedWorkingCopyID != id else { return }

        suppressedSelectionReloadID = id
        selectedWorkingCopyID = id
        clearHistory()
        clearStatusEntries()
        selectedEntryIDs = []
        await reloadSelectedWorkingCopy()
    }

    func requestDirectoryImport() {
        guard !isBusy, !hasBlockingPresentation else { return }
        isPresentingDirectoryImporter = true
    }

    func retryFinderQueueRecovery() async {
        isFinderQueueRecoveryPaused = false
        finderQueueRecoveryErrorID = nil
        presentedError = nil
        await processPendingFinderCommands()
    }

    /// Establishes the App's process-lifetime queue lease before recovering
    /// only App-owned claims. A second App instance stays read-only for Finder
    /// requests while the live owner retains the advisory lock.
    private func prepareFinderQueueIfNeeded() async -> Bool {
        guard let coordinator = finderQueueCoordinator else { return false }
        if finderConsumerLease != nil, didRecoverFinderClaims {
            return true
        }
        if isPreparingFinderQueue {
            while isPreparingFinderQueue {
                do {
                    try await Task.sleep(for: .milliseconds(20))
                } catch {
                    return false
                }
            }
            return finderConsumerLease != nil && didRecoverFinderClaims
        }

        isPreparingFinderQueue = true
        defer { isPreparingFinderQueue = false }

        do {
            if finderConsumerLease == nil {
                finderConsumerLease = try await coordinator.acquireConsumerLease(
                    for: .application
                )
            }
            guard let lease = finderConsumerLease else {
                // Another live App owns this consumer role. Launch Services
                // normally routes the URL to that process, so this instance
                // must not recover or claim its files.
                return false
            }
            if !didRecoverFinderClaims {
                _ = try await coordinator.recoverOrphanedClaims(
                    for: .application,
                    lease: lease
                )
                didRecoverFinderClaims = true
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            pauseFinderQueueRecovery(
                for: error,
                title: "无法恢复 Finder 操作"
            )
            return false
        }
    }

    /// Loading belongs to the shared store rather than any one window. An
    /// unstructured task survives SwiftUI cancelling a disappearing view's
    /// task, and reopening a window preserves the current selection and draft.
    func startIfNeeded() async {
        if let startupTask {
            await startupTask.value
            return
        }
        guard !hasStarted else { return }

        let task = Task { [self] in
            defer { startupTask = nil }
            guard await load() else { return }
            hasStarted = true
            await processPendingFinderCommands()
        }
        startupTask = task
        await task.value
    }

    @discardableResult
    func load() async -> Bool {
        guard await waitForFinderRoutingToFinish() else { return false }
        _ = await prepareFinderQueueIfNeeded()
        return await perform(kind: .loading) { [self] in
            let loadedCopies = try await service.loadRegisteredWorkingCopies()
            workingCopies = loadedCopies.sorted(by: Self.copySort)

            if !workingCopies.contains(where: { $0.id == selectedWorkingCopyID }) {
                let nextID = workingCopies.first?.id
                if selectedWorkingCopyID != nextID {
                    suppressedSelectionReloadID = nextID
                    selectedWorkingCopyID = nextID
                }
            }

            guard let workingCopy = selectedWorkingCopy else {
                clearStatusEntries()
                return
            }

            let loadedEntries = try await loadStatusSnapshot(for: workingCopy)
            guard selectedWorkingCopyID == workingCopy.id else { return }
            apply(loadedEntries, to: workingCopy.id)
        }
    }

    func reloadSelectedWorkingCopy(
        allowDuringFinderRouting: Bool = false
    ) async {
        if !allowDuringFinderRouting,
           !(await waitForFinderRoutingToFinish()) {
            return
        }

        guard let workingCopy = selectedWorkingCopy else {
            clearStatusEntries()
            selectedEntryIDs = []
            diffText = ""
            clearHistory()
            return
        }

        let expectedID = workingCopy.id
        await perform(
            kind: .refreshing,
            detail: workingCopy.name,
            allowDuringFinderRouting: allowDuringFinderRouting
        ) { [self] in
            guard selectedWorkingCopyID == expectedID else { return }
            selectedEntryIDs = []
            diffText = ""
            let loadedEntries = try await loadStatusSnapshot(for: workingCopy)
            guard selectedWorkingCopyID == expectedID else { return }
            apply(loadedEntries, to: expectedID)
            invalidateRemoteStatus(for: expectedID)
            let metadata = try? await service.refreshWorkingCopyMetadata(for: workingCopy)
            guard selectedWorkingCopyID == expectedID,
                  let index = workingCopies.firstIndex(where: { $0.id == expectedID }) else { return }
            workingCopies[index].repositoryURL = metadata?.repositoryURL
            workingCopies[index].revision = metadata?.revision
        }
    }

    func registerWorkingCopies(at urls: [URL]) async {
        guard !urls.isEmpty else { return }
        guard await waitForFinderRoutingToFinish() else { return }

        await perform(kind: .loading, detail: "登记工作副本") { [self] in
            var newlyRegistered: [SvnDockWorkingCopy] = []
            var registrationErrors: [String] = []

            for url in urls {
                let hasScopedAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if hasScopedAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    let copy = try await service.registerWorkingCopy(at: url)
                    newlyRegistered.append(copy)
                } catch {
                    registrationErrors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }

            for copy in newlyRegistered {
                if let index = workingCopies.firstIndex(where: { $0.id == copy.id || $0.rootURL == copy.rootURL }) {
                    workingCopies[index] = copy
                } else {
                    workingCopies.append(copy)
                }
            }
            workingCopies.sort(by: Self.copySort)

            if let first = newlyRegistered.first {
                if selectedWorkingCopyID != first.id {
                    suppressedSelectionReloadID = first.id
                    selectedWorkingCopyID = first.id
                }
            }

            if !registrationErrors.isEmpty {
                presentedError = SvnDockUserFacingError(
                    title: "部分目录无法添加",
                    message: registrationErrors.joined(separator: "\n")
                )
            }
        }

        await reloadSelectedWorkingCopy()
    }

    func requestRemoval(of workingCopy: SvnDockWorkingCopy? = nil) {
        guard !isInteractionBlocked,
              let requestedCopy = workingCopy ?? selectedWorkingCopy else { return }
        pendingRemoval = requestedCopy
        isPresentingRemovalConfirmation = true
    }

    func cancelRemoval() {
        pendingRemoval = nil
        isPresentingRemovalConfirmation = false
    }

    func confirmRemoval() {
        guard let workingCopy = pendingRemoval, activeOperation == nil else {
            cancelRemoval()
            return
        }

        pendingRemoval = nil
        activeOperation = SvnDockOperationState(
            kind: .loading,
            detail: "移除 \(workingCopy.name)"
        )
        isPresentingRemovalConfirmation = false

        Task { [weak self] in
            await self?.executeConfirmedRemoval(workingCopy)
        }
    }

    private func executeConfirmedRemoval(_ workingCopy: SvnDockWorkingCopy) async {
        var succeeded = false
        do {
            try await service.unregisterWorkingCopy(id: workingCopy.id)
            workingCopies.removeAll { $0.id == workingCopy.id }
            if historyTarget?.workingCopy.id == workingCopy.id {
                clearHistory()
            }
            if selectedWorkingCopyID == workingCopy.id {
                let nextID = workingCopies.first?.id
                if let nextID {
                    suppressedSelectionReloadID = nextID
                }
                selectedWorkingCopyID = nextID
                clearStatusEntries()
                selectedEntryIDs = []
                diffText = ""
            }
            succeeded = true
        } catch is CancellationError {
            // A cancelled removal leaves the registry unchanged.
        } catch {
            present(error, title: operationFailureTitle(for: .loading))
        }

        activeOperation = nil
        if succeeded, selectedWorkingCopyID != nil {
            await reloadSelectedWorkingCopy()
        }
        await processPendingFinderCommands()
    }

    func updateSelectedWorkingCopy(
        allowDuringFinderRouting: Bool = false
    ) async {
        if !allowDuringFinderRouting,
           !(await waitForFinderRoutingToFinish()) {
            return
        }
        guard let workingCopy = selectedWorkingCopy else {
            present(SvnDockServiceError.noWorkingCopySelected, title: "无法更新")
            return
        }
        await update(
            workingCopyIDs: [workingCopy.id],
            allowDuringFinderRouting: allowDuringFinderRouting
        )
    }

    @discardableResult
    func update(
        workingCopyIDs: Set<UUID>,
        allowDuringFinderRouting: Bool = false
    ) async -> Bool {
        if !allowDuringFinderRouting,
           !(await waitForFinderRoutingToFinish()) {
            return false
        }
        let copies = workingCopies.filter { workingCopyIDs.contains($0.id) }
        guard !copies.isEmpty else { return false }
        for copy in copies { invalidateRemoteStatus(for: copy.id) }

        let detail = copies.count == 1 ? copies[0].name : "\(copies.count) 个工作副本"
        var allSucceeded = true
        let succeeded = await perform(
            kind: .updating,
            detail: detail,
            allowDuringFinderRouting: allowDuringFinderRouting
        ) { [self] in
            for copy in copies {
                try Task.checkCancellation()
                let startedAt = Date()
                do {
                    try await service.update(workingCopies: [copy])
                    try Task.checkCancellation()
                    recordOperation(.init(workingCopy: copy, actionTitle: "更新", startedAt: startedAt,
                                          outcome: .success, summary: "更新命令完成，请检查本地状态与冲突"))
                } catch is CancellationError {
                    recordOperation(.init(workingCopy: copy, actionTitle: "更新", startedAt: startedAt,
                                          outcome: .uncertain, summary: "更新已中断，本地文件可能已部分更新",
                                          detail: "请刷新该工作副本的状态，检查冲突后再继续。未自动重试。"))
                    throw CancellationError()
                } catch {
                    allSucceeded = false
                    recordOperation(.init(workingCopy: copy, actionTitle: "更新", startedAt: startedAt,
                                          outcome: .failure, summary: "更新未完成，请检查本地状态",
                                          detail: error.localizedDescription))
                }
            }
        }

        if let selectedWorkingCopyID, workingCopyIDs.contains(selectedWorkingCopyID) {
            await reloadSelectedWorkingCopy(
                allowDuringFinderRouting: allowDuringFinderRouting
            )
        }
        return succeeded && allSucceeded
    }

    func requestCommit(
        allowDuringFinderRouting: Bool = false,
        finderClaim: FinderCommandClaim? = nil
    ) {
        guard allowDuringFinderRouting || !isInteractionBlocked else { return }
        guard hasPendingChanges else { return }
        pendingCommitClaim = finderClaim
        isPresentingCommit = true
    }

    func cancelCommit() {
        isPresentingCommit = false
        commitPresentationDidDismiss()
    }

    /// Handles both the explicit Cancel button and native sheet dismissal.
    /// A successful commit clears the claim before dismissing, so this method
    /// cannot accidentally turn a completed request into a cancellation.
    func commitPresentationDidDismiss() {
        guard !isPresentingCommit, let claim = pendingCommitClaim else { return }
        pendingCommitClaim = nil
        finalizeAwaitingFinderClaim(claim, outcome: .cancelled)
    }

    /// Captures the exact commit request and publishes busy state before the
    /// button action returns. This closes the double-click/cancel window in
    /// which two Tasks could otherwise race the same awaiting-user claim.
    func commit(message: String, entryIDs: Set<SvnDockStatusEntry.ID>) {
        guard activeOperation == nil else { return }
        guard let workingCopy = selectedWorkingCopy else {
            present(SvnDockServiceError.noWorkingCopySelected, title: "无法提交")
            return
        }

        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessage.isEmpty else {
            present(SvnDockServiceError.emptyCommitMessage, title: "无法提交")
            return
        }

        let selectedEntries = entries.filter { entryIDs.contains($0.id) && $0.status.canCommit }
        guard !selectedEntries.isEmpty else {
            present(SvnDockServiceError.noCommittableFiles, title: "无法提交")
            return
        }

        let request = PendingCommitExecution(
            workingCopy: workingCopy,
            relativePaths: selectedEntries.map(\.relativePath),
            message: normalizedMessage,
            finderClaim: pendingCommitClaim
        )
        pendingCommitClaim = nil
        invalidateRemoteStatus(for: workingCopy.id)
        activeOperation = SvnDockOperationState(
            kind: .committing,
            detail: workingCopy.name
        )

        Task { [weak self] in
            await self?.executeCommit(request)
        }
    }

    private func executeCommit(_ request: PendingCommitExecution) async {
        let startedAt = Date()
        let executingClaim: FinderCommandClaim?
        do {
            executingClaim = try await markFinderClaimExecuting(request.finderClaim)
        } catch {
            if let finderClaim = request.finderClaim {
                _ = await acknowledgeFinderClaim(finderClaim, outcome: .rejected)
            }
            activeOperation = nil
            present(error, title: "无法开始 Finder 提交")
            return
        }

        var succeeded = false
        var commitError: Error?
        do {
            try Task.checkCancellation()
            try await service.commit(
                workingCopy: request.workingCopy,
                relativePaths: request.relativePaths,
                message: request.message
            )
            succeeded = true
        } catch is CancellationError {
            commitError = CancellationError()
            if let executingClaim {
                await quarantineExecutedFinderClaim(executingClaim)
            }
        } catch {
            commitError = error
            if let executingClaim {
                await quarantineExecutedFinderClaim(executingClaim)
            }
            present(error, title: operationFailureTitle(for: .committing))
        }

        if succeeded, Task.isCancelled {
            if let executingClaim {
                await quarantineExecutedFinderClaim(executingClaim)
            }
        } else if succeeded, let executingClaim {
            _ = await acknowledgeFinderClaim(executingClaim, outcome: .completed)
        }

        if succeeded, !Task.isCancelled {
            commitDraftStore.remove(for: request.workingCopy)
        }
        let outcome: SvnDockOperationRecord.Outcome
        if succeeded, !Task.isCancelled {
            outcome = .success
        } else if let error = commitError as? SVNSelectedCommitError,
                  Self.isPreflightFailure(error) {
            outcome = .failure
        } else if commitError is SVNCommandBuilderError {
            outcome = .failure
        } else {
            outcome = .uncertain
        }
        let summary = outcome == .success ? "提交完成，可在历史中查看"
            : outcome == .failure ? "提交前检查未通过，草稿已保留"
            : "提交结果待确认，草稿已保留"
        recordOperation(.init(workingCopy: request.workingCopy, actionTitle: "提交", startedAt: startedAt,
                              outcome: outcome, summary: summary,
                              detail: outcome == .uncertain
                                ? "请先检查仓库历史与本地状态，确认是否已提交，再决定是否重试。\n\(commitError?.localizedDescription ?? "操作已中断。")"
                                : commitError?.localizedDescription))
        activeOperation = nil
        if succeeded {
            await reloadSelectedWorkingCopy(allowDuringFinderRouting: true)
            isPresentingCommit = false
            await processPendingFinderCommands()
        }
    }

    private static func isPreflightFailure(_ error: SVNSelectedCommitError) -> Bool {
        switch error {
        case .changedSelection, .missingParent, .externalWorkingCopy: true
        case .commandFailed: false
        }
    }

    @discardableResult
    func addSelectedEntries(
        entryIDs: Set<SvnDockStatusEntry.ID>? = nil,
        allowDuringFinderRouting: Bool = false
    ) async -> Bool {
        guard let workingCopy = selectedWorkingCopy else { return false }
        let targetIDs = entryIDs ?? selectedEntryIDs
        let selected = targetIDs.compactMap { statusEntry(withID: $0) }
        guard selected.count == targetIDs.count, !selected.isEmpty,
              selected.allSatisfy({ entry in
                  entry.workingCopyID == workingCopy.id
                      && (entry.status == .unversioned
                          || (entry.status == .added && entry.nodeKind == .directory))
              }) else { return false }
        if !allowDuringFinderRouting,
           !(await waitForFinderRoutingToFinish()) {
            return false
        }
        guard selectedWorkingCopyID == workingCopy.id else { return false }

        let succeeded = await perform(
            kind: .adding,
            detail: "\(selected.count) 个项目",
            allowDuringFinderRouting: allowDuringFinderRouting
        ) { [self] in
            try await service.add(
                relativePaths: selected.map(\.relativePath),
                in: workingCopy
            )
        }
        await reloadSelectedWorkingCopy(
            allowDuringFinderRouting: allowDuringFinderRouting
        )
        return succeeded
    }

    func requestUnscheduleAddConfirmation(
        for entry: SvnDockStatusEntry? = nil,
        allowDuringFinderRouting: Bool = false,
        finderClaim: FinderCommandClaim? = nil
    ) {
        guard allowDuringFinderRouting || !isInteractionBlocked else { return }
        guard let workingCopy = selectedWorkingCopy else { return }

        let selected: [SvnDockStatusEntry]
        if let entry,
           let currentEntry = statusEntry(withID: entry.id),
           currentEntry.status == .added {
            selected = [currentEntry]
        } else if entry == nil {
            selected = selectedStatusEntries { $0.status == .added }
        } else {
            selected = []
        }
        guard !selected.isEmpty else {
            present(
                SvnDockServiceError.noScheduledAdditions,
                title: "无法取消添加"
            )
            return
        }

        pendingUnscheduleAdd = PendingUnscheduleAdd(
            workingCopy: workingCopy,
            relativePaths: selected.map(\.relativePath),
            finderClaim: finderClaim,
            missingOnly: false
        )
        isPresentingUnscheduleAddConfirmation = true
    }

    func requestMissingAdditionCleanup(for entry: SvnDockStatusEntry? = nil, allMissing: Bool = false) {
        guard !isInteractionBlocked, let workingCopy = selectedWorkingCopy else { return }
        let selected: [SvnDockStatusEntry]
        if allMissing {
            selected = statusSnapshot.missingEntries.filter {
                $0.workingCopyID == workingCopy.id && $0.isMissingScheduledAddition
            }
        } else {
            selected = missingActionEntries(for: entry)
        }
        guard !selected.isEmpty, selected.allSatisfy(\.isMissingScheduledAddition) else { return }
        pendingUnscheduleAdd = PendingUnscheduleAdd(
            workingCopy: workingCopy,
            relativePaths: selected.map(\.relativePath),
            finderClaim: nil,
            missingOnly: true
        )
        isPresentingUnscheduleAddConfirmation = true
    }

    // A context action applies to the selection only when its row belongs to
    // it. Never fall back to unrelated selected paths for a stale context row.
    private func missingActionEntries(for entry: SvnDockStatusEntry?) -> [SvnDockStatusEntry] {
        guard let workingCopy = selectedWorkingCopy else { return [] }
        if let entry {
            guard entry.workingCopyID == workingCopy.id,
                  let current = statusEntry(withID: entry.id),
                  current.workingCopyID == workingCopy.id else { return [] }
            if !selectedEntryIDs.contains(current.id) { return [current] }
        }
        let selected = selectedEntryIDs.compactMap(statusEntry(withID:))
        guard selected.count == selectedEntryIDs.count,
              selected.allSatisfy({ $0.workingCopyID == workingCopy.id }) else { return [] }
        return selected.sorted { $0.relativePath < $1.relativePath }
    }

    func canScheduleMissingDeletion(for entry: SvnDockStatusEntry) -> Bool {
        let selected = missingActionEntries(for: entry)
        return !selected.isEmpty && selected.allSatisfy { $0.isMissingVersioned && $0.relativePath != "." }
    }

    func canCleanupMissingAdditions(for entry: SvnDockStatusEntry) -> Bool {
        let selected = missingActionEntries(for: entry)
        return !selected.isEmpty && selected.allSatisfy(\.isMissingScheduledAddition)
    }

    func requestMissingDeletion(for entry: SvnDockStatusEntry? = nil, allMissing: Bool = false) {
        guard !isInteractionBlocked, let workingCopy = selectedWorkingCopy else { return }
        let selected = allMissing
            ? statusSnapshot.missingEntries.filter { $0.workingCopyID == workingCopy.id && $0.isMissingVersioned }
            : missingActionEntries(for: entry)
        guard !selected.isEmpty,
              selected.allSatisfy({ $0.isMissingVersioned && $0.relativePath != "." }) else { return }
        pendingMissingDeletion = PendingMissingDeletion(
            workingCopy: workingCopy,
            relativePaths: selected.map(\.relativePath)
        )
        isPresentingMissingDeletionConfirmation = true
    }

    var missingDeletionConfirmationMessage: String {
        guard let request = pendingMissingDeletion else { return "" }
        let paths = request.relativePaths.prefix(5).joined(separator: "\n")
        let summary = request.relativePaths.count > 5 ? paths + "\n等 \(request.relativePaths.count) 个项目" : paths
        return "将这些已纳管且本地缺失的项目标记为 SVN 删除，目录包含其子项。标记后请在提交窗口中提交删除，仓库中的文件才会移除。提交前可通过还原撤销。\n\n\(summary)"
    }

    func cancelMissingDeletionConfirmation() {
        pendingMissingDeletion = nil
        isPresentingMissingDeletionConfirmation = false
    }

    func confirmMissingDeletion() {
        guard let request = pendingMissingDeletion, activeOperation == nil else {
            cancelMissingDeletionConfirmation()
            return
        }
        pendingMissingDeletion = nil
        activeOperation = SvnDockOperationState(kind: .deleting, detail: "\(request.relativePaths.count) 个项目")
        isPresentingMissingDeletionConfirmation = false
        Task { [weak self] in
            await self?.executeConfirmedMissingDeletion(request)
        }
    }

    private func executeConfirmedMissingDeletion(_ request: PendingMissingDeletion) async {
        do {
            try Task.checkCancellation()
            try await service.scheduleMissingDeletion(relativePaths: request.relativePaths, in: request.workingCopy)
        } catch is CancellationError {
            // Do not retry a mutation automatically after cancellation.
        } catch {
            present(error, title: operationFailureTitle(for: .deleting))
        }
        activeOperation = nil
        // SVN can fail after changing some targets. Refresh even on failure so
        // the user sees the actual schedules before deciding what to do next.
        if selectedWorkingCopyID == request.workingCopy.id {
            await reloadSelectedWorkingCopy(allowDuringFinderRouting: true)
        }
        await processPendingFinderCommands()
    }

    var isConfirmingMissingAdditionCleanup: Bool { pendingUnscheduleAdd?.missingOnly == true }

    var unscheduleAddConfirmationMessage: String {
        guard let request = pendingUnscheduleAdd else { return "" }
        let paths = request.relativePaths.prefix(3).joined(separator: "\n")
        let summary = request.relativePaths.count > 3 ? paths + "\n等 \(request.relativePaths.count) 个项目" : paths
        if request.missingOnly {
            return "将取消缺失项目尚未提交的添加计划，目录包含其子项。不会恢复文件、删除磁盘内容或提交仓库变更。若发现已纳管或状态已变化的项目，本次清理将停止。\n\n\(summary)"
        }
        return "文件和目录会保留在磁盘上，但将恢复为未纳管状态，不会包含在下次提交中。\n\n\(summary)"
    }

    func cancelUnscheduleAddConfirmation() {
        let finderClaim = pendingUnscheduleAdd?.finderClaim
        pendingUnscheduleAdd = nil
        isPresentingUnscheduleAddConfirmation = false
        finalizeAwaitingFinderClaim(finderClaim, outcome: .cancelled)
    }

    /// Captures the confirmed paths before closing the alert so Finder cannot
    /// replace the selection while cancellation is being scheduled.
    func confirmUnscheduleAdd() {
        guard let request = pendingUnscheduleAdd, activeOperation == nil else {
            cancelUnscheduleAddConfirmation()
            return
        }

        pendingUnscheduleAdd = nil
        activeOperation = SvnDockOperationState(
            kind: .unschedulingAdd,
            detail: "\(request.relativePaths.count) 个项目"
        )
        isPresentingUnscheduleAddConfirmation = false

        Task { [weak self] in
            await self?.executeConfirmedUnscheduleAdd(request)
        }
    }

    private func executeConfirmedUnscheduleAdd(
        _ request: PendingUnscheduleAdd
    ) async {
        let executingClaim: FinderCommandClaim?
        do {
            executingClaim = try await markFinderClaimExecuting(request.finderClaim)
        } catch {
            if let finderClaim = request.finderClaim {
                _ = await acknowledgeFinderClaim(finderClaim, outcome: .rejected)
            }
            activeOperation = nil
            present(error, title: "无法开始 Finder 取消添加")
            await processPendingFinderCommands()
            return
        }

        var succeeded = false
        do {
            try Task.checkCancellation()
            if request.missingOnly {
                try await service.cleanupMissingAdditions(relativePaths: request.relativePaths, in: request.workingCopy)
            } else {
                try await service.unscheduleAdd(relativePaths: request.relativePaths, in: request.workingCopy)
            }
            succeeded = true
        } catch is CancellationError {
            if let executingClaim {
                await quarantineExecutedFinderClaim(executingClaim)
            }
        } catch {
            if let executingClaim {
                await quarantineExecutedFinderClaim(executingClaim)
            }
            present(error, title: operationFailureTitle(for: .unschedulingAdd))
        }

        if succeeded, Task.isCancelled {
            if let executingClaim {
                await quarantineExecutedFinderClaim(executingClaim)
            }
        } else if succeeded, let executingClaim {
            _ = await acknowledgeFinderClaim(executingClaim, outcome: .completed)
        }
        activeOperation = nil
        if selectedWorkingCopyID == request.workingCopy.id {
            await reloadSelectedWorkingCopy(allowDuringFinderRouting: true)
        }
        await processPendingFinderCommands()
    }

    func requestRevertConfirmation(
        allowDuringFinderRouting: Bool = false,
        finderClaim: FinderCommandClaim? = nil
    ) {
        guard allowDuringFinderRouting || !isInteractionBlocked else { return }
        guard let workingCopy = selectedWorkingCopy else { return }
        let selected = selectedStatusEntries { $0.status.isChange }
        guard !selected.isEmpty else { return }

        pendingRevert = PendingRevert(
            workingCopy: workingCopy,
            relativePaths: selected.map(\.relativePath),
            finderClaim: finderClaim
        )
        isPresentingRevertConfirmation = true
    }

    func cancelRevertConfirmation() {
        let finderClaim = pendingRevert?.finderClaim
        pendingRevert = nil
        isPresentingRevertConfirmation = false
        finalizeAwaitingFinderClaim(finderClaim, outcome: .cancelled)
    }

    var revertConfirmationMessage: String {
        guard let request = pendingRevert else { return "请重新选择需要还原的项目。" }
        let paths = request.relativePaths.sorted()
        let preview = paths.prefix(10).joined(separator: "\n")
        let remaining = paths.count > 10 ? "\n另有 \(paths.count - 10) 项" : ""
        return "工作副本：\(request.workingCopy.name)\n将还原 \(paths.count) 项：\n\(preview)\(remaining)\n\n普通目录仅还原自身属性；缺失、待删除或待添加目录可能递归恢复内容或取消添加计划。所选项目的未提交修改会丢弃，SvnDock 无法撤销。"
    }

    /// Captures the exact working copy and paths before dismissing the alert,
    /// then publishes the busy state synchronously. A waiting Finder request
    /// therefore cannot replace the selection before the revert starts.
    func confirmRevert() {
        guard let request = pendingRevert, activeOperation == nil else {
            cancelRevertConfirmation()
            return
        }

        pendingRevert = nil
        activeOperation = SvnDockOperationState(
            kind: .reverting,
            detail: "\(request.relativePaths.count) 个项目"
        )
        isPresentingRevertConfirmation = false

        Task { [weak self] in
            await self?.executeConfirmedRevert(request)
        }
    }

    private func executeConfirmedRevert(_ request: PendingRevert) async {
        let executingClaim: FinderCommandClaim?
        do {
            executingClaim = try await markFinderClaimExecuting(request.finderClaim)
        } catch {
            if let finderClaim = request.finderClaim {
                _ = await acknowledgeFinderClaim(finderClaim, outcome: .rejected)
            }
            activeOperation = nil
            present(error, title: "无法开始 Finder 还原")
            await processPendingFinderCommands()
            return
        }

        var succeeded = false
        do {
            try Task.checkCancellation()
            try await service.revert(
                relativePaths: request.relativePaths,
                in: request.workingCopy
            )
            succeeded = true
        } catch is CancellationError {
            // The selection snapshot remains valid, but a cancelled operation
            // is intentionally not retried without another confirmation.
            if let executingClaim {
                await quarantineExecutedFinderClaim(executingClaim)
            }
        } catch {
            if let executingClaim {
                await quarantineExecutedFinderClaim(executingClaim)
            }
            present(error, title: operationFailureTitle(for: .reverting))
        }

        if succeeded, Task.isCancelled {
            if let executingClaim {
                await quarantineExecutedFinderClaim(executingClaim)
            }
        } else if succeeded, let executingClaim {
            _ = await acknowledgeFinderClaim(executingClaim, outcome: .completed)
        }
        activeOperation = nil
        if succeeded, selectedWorkingCopyID == request.workingCopy.id {
            await reloadSelectedWorkingCopy()
        }
        await processPendingFinderCommands()
    }

    func requestResolveConfirmation(
        for entry: SvnDockStatusEntry? = nil,
        allowDuringFinderRouting: Bool = false,
        finderClaim: FinderCommandClaim? = nil
    ) {
        guard allowDuringFinderRouting || !isInteractionBlocked else { return }
        guard let workingCopy = selectedWorkingCopy else { return }

        let selected: [SvnDockStatusEntry]
        if let entry {
            selected = entries.filter { $0.id == entry.id && $0.status == .conflicted }
        } else {
            selected = entries.filter {
                selectedEntryIDs.contains($0.id) && $0.status == .conflicted
            }
        }
        guard !selected.isEmpty else {
            present(SvnDockServiceError.noConflictedFiles, title: "无法解决冲突")
            return
        }

        let allowsReplacement = selected.allSatisfy {
            $0.nodeKind == .file && $0.conflictKinds == [.text]
        }
        pendingResolve = PendingResolve(
            workingCopy: workingCopy,
            relativePaths: selected.map(\.relativePath),
            displayName: selected.count == 1 ? selected[0].fileName : "\(selected.count) 个项目",
            allowsFileReplacement: allowsReplacement,
            finderClaim: finderClaim
        )
        isPresentingResolveConfirmation = true
    }

    func cancelResolveConfirmation() {
        let finderClaim = pendingResolve?.finderClaim
        pendingResolve = nil
        isPresentingResolveConfirmation = false
        finalizeAwaitingFinderClaim(finderClaim, outcome: .cancelled)
    }

    func confirmResolve(using resolution: SvnDockConflictResolution) {
        guard let request = pendingResolve,
              activeOperation == nil,
              resolution == .working || request.allowsFileReplacement else {
            cancelResolveConfirmation()
            return
        }

        pendingResolve = nil
        activeOperation = SvnDockOperationState(
            kind: .resolving,
            detail: request.displayName
        )
        isPresentingResolveConfirmation = false

        Task { [weak self] in
            await self?.executeConfirmedResolve(request, resolution: resolution)
        }
    }

    private func executeConfirmedResolve(
        _ request: PendingResolve,
        resolution: SvnDockConflictResolution
    ) async {
        let executingClaim: FinderCommandClaim?
        do {
            executingClaim = try await markFinderClaimExecuting(request.finderClaim)
        } catch {
            if let finderClaim = request.finderClaim {
                _ = await acknowledgeFinderClaim(finderClaim, outcome: .rejected)
            }
            activeOperation = nil
            present(error, title: "无法开始 Finder 冲突处理")
            await processPendingFinderCommands()
            return
        }

        var succeeded = false
        do {
            try Task.checkCancellation()
            try await service.resolve(
                relativePaths: request.relativePaths,
                using: resolution,
                in: request.workingCopy
            )
            succeeded = true
        } catch is CancellationError {
            // A conflict strategy is never retried without fresh confirmation.
            if let executingClaim {
                await quarantineExecutedFinderClaim(executingClaim)
            }
        } catch {
            if let executingClaim {
                await quarantineExecutedFinderClaim(executingClaim)
            }
            present(error, title: operationFailureTitle(for: .resolving))
        }

        if succeeded, Task.isCancelled {
            if let executingClaim {
                await quarantineExecutedFinderClaim(executingClaim)
            }
        } else if succeeded, let executingClaim {
            _ = await acknowledgeFinderClaim(executingClaim, outcome: .completed)
        }
        activeOperation = nil
        if succeeded, selectedWorkingCopyID == request.workingCopy.id {
            await reloadSelectedWorkingCopy()
        }
        await processPendingFinderCommands()
    }

    func requestIgnoreConfirmation(
        for entry: SvnDockStatusEntry,
        mode: SvnDockIgnoreMode,
        allowDuringFinderRouting: Bool = false,
        finderClaim: FinderCommandClaim? = nil
    ) {
        guard allowDuringFinderRouting || !isInteractionBlocked else { return }
        guard let workingCopy = selectedWorkingCopy,
              let currentEntry = statusEntry(withID: entry.id),
              currentEntry.status == .unversioned else {
            present(
                SvnDockServiceError.invalidIgnoreTarget("所选项目已经不再是未纳管状态。"),
                title: "无法添加忽略规则"
            )
            return
        }

        do {
            let rule = try makeIgnoreRule(for: currentEntry, mode: mode)
            let description = mode == .name
                ? "忽略名称“\(rule.pattern)”"
                : "忽略所有“\(rule.pattern)”文件"
            pendingIgnore = PendingIgnore(
                workingCopy: workingCopy,
                rules: [rule],
                message: "将\(description)，规则写入“\(rule.parentRelativePath)”的 svn:ignore 属性。父目录会显示为已修改，需要提交后才能与团队共享。",
                finderClaim: finderClaim
            )
            isPresentingIgnoreConfirmation = true
        } catch {
            present(error, title: "无法添加忽略规则")
        }
    }

    func cancelIgnoreConfirmation() {
        let finderClaim = pendingIgnore?.finderClaim
        pendingIgnore = nil
        isPresentingIgnoreConfirmation = false
        finalizeAwaitingFinderClaim(finderClaim, outcome: .cancelled)
    }

    func confirmIgnore() {
        guard let request = pendingIgnore, activeOperation == nil else {
            cancelIgnoreConfirmation()
            return
        }

        pendingIgnore = nil
        activeOperation = SvnDockOperationState(
            kind: .ignoring,
            detail: request.rules.first?.pattern
        )
        isPresentingIgnoreConfirmation = false

        Task { [weak self] in
            await self?.executeConfirmedIgnore(request)
        }
    }

    private func executeConfirmedIgnore(_ request: PendingIgnore) async {
        let executingClaim: FinderCommandClaim?
        do {
            executingClaim = try await markFinderClaimExecuting(request.finderClaim)
        } catch {
            if let finderClaim = request.finderClaim {
                _ = await acknowledgeFinderClaim(finderClaim, outcome: .rejected)
            }
            activeOperation = nil
            present(error, title: "无法开始 Finder 忽略操作")
            await processPendingFinderCommands()
            return
        }

        var succeeded = false
        do {
            try Task.checkCancellation()
            try await service.addIgnoreRules(request.rules, in: request.workingCopy)
            succeeded = true
        } catch is CancellationError {
            // Ignore mutations are not retried without another confirmation.
            if let executingClaim {
                await quarantineExecutedFinderClaim(executingClaim)
            }
        } catch {
            if let executingClaim {
                await quarantineExecutedFinderClaim(executingClaim)
            }
            present(
                error,
                title: "添加忽略规则失败（部分目录可能已经更新）"
            )
        }

        if succeeded, Task.isCancelled {
            if let executingClaim {
                await quarantineExecutedFinderClaim(executingClaim)
            }
        } else if succeeded, let executingClaim {
            _ = await acknowledgeFinderClaim(executingClaim, outcome: .completed)
        }
        activeOperation = nil
        if selectedWorkingCopyID == request.workingCopy.id {
            // Refresh even after failure because a multi-directory property
            // update can only provide best-effort partial completion.
            await reloadSelectedWorkingCopy(allowDuringFinderRouting: true)
        }
        await processPendingFinderCommands()
    }

    private func makeIgnoreRule(
        for entry: SvnDockStatusEntry,
        mode: SvnDockIgnoreMode
    ) throws -> SvnDockIgnoreRule {
        guard entry.relativePath != "." else {
            throw SvnDockServiceError.invalidIgnoreTarget("不能忽略工作副本根目录。")
        }

        let path = entry.relativePath as NSString
        let parent = path.deletingLastPathComponent
        let name = path.lastPathComponent
        let pattern: String

        switch mode {
        case .name:
            pattern = name
        case .fileExtension:
            guard entry.nodeKind == .file else {
                throw SvnDockServiceError.invalidIgnoreTarget("只有文件可以按扩展名忽略。")
            }
            let fileExtension = path.pathExtension
            guard !fileExtension.isEmpty else {
                throw SvnDockServiceError.invalidIgnoreTarget("这个文件没有可用于忽略的扩展名。")
            }
            pattern = "*.\(fileExtension)"
        }

        let literalComponent = mode == .name ? pattern : path.pathExtension
        let unsafeCharacters = CharacterSet(charactersIn: "*?[]\\\n\r\0")
        guard !literalComponent.isEmpty,
              literalComponent.rangeOfCharacter(from: unsafeCharacters) == nil else {
            throw SvnDockServiceError.invalidIgnoreTarget(
                "名称包含 SVN 通配符或控制字符，无法安全生成忽略规则。"
            )
        }

        return SvnDockIgnoreRule(
            targetRelativePath: entry.relativePath,
            parentRelativePath: parent.isEmpty ? "." : parent,
            pattern: pattern,
            mode: mode
        )
    }

    @discardableResult
    func cleanupSelectedWorkingCopy(
        allowDuringFinderRouting: Bool = false
    ) async -> Bool {
        if !allowDuringFinderRouting,
           !(await waitForFinderRoutingToFinish()) {
            return false
        }
        guard let workingCopy = selectedWorkingCopy else { return false }
        let succeeded = await perform(
            kind: .cleaning,
            detail: workingCopy.name,
            allowDuringFinderRouting: allowDuringFinderRouting
        ) { [self] in
            try await service.cleanup(workingCopy: workingCopy)
        }
        await reloadSelectedWorkingCopy(
            allowDuringFinderRouting: allowDuringFinderRouting
        )
        return succeeded
    }

    /// Resolves one opaque request ID written by the Finder extension. Paths
    /// remain in the App Group queue and never travel through the custom URL.
    func handleFinderURL(_ url: URL) async {
        guard url.scheme?.lowercased() == "svndock",
              url.host == "finder-command",
              finderQueueCoordinator != nil else { return }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let idText = components?.queryItems?.first(where: { $0.name == "request" })?.value,
              let requestID = UUID(uuidString: idText) else {
            return
        }

        // A fresh Finder action is an explicit retry signal after a prior
        // shared-directory enumeration failure in this app session.
        isFinderQueueRecoveryPaused = false
        guard await prepareFinderQueueIfNeeded() else { return }
        await processFinderCommand(id: requestID, waitForAgentHandoff: true)
        await processPendingFinderCommands()
    }

    /// Recovers valid requests left behind when Finder successfully wrote the
    /// queue file but the custom-URL wake-up was dropped by Launch Services.
    /// Stop after presenting interactive UI so a later request cannot replace
    /// the user's current confirmation context.
    func processPendingFinderCommands() async {
        guard let coordinator = finderQueueCoordinator,
              !isFinderQueueRecoveryPaused,
              !isDrainingFinderQueue else { return }
        guard await prepareFinderQueueIfNeeded() else { return }

        isDrainingFinderQueue = true
        defer { isDrainingFinderQueue = false }

        do {
            let commandIDs = try await coordinator.availableCommandIDs(for: .application)
            for commandID in commandIDs {
                await processFinderCommand(id: commandID)
                if hasBlockingPresentation {
                    break
                }
            }
        } catch is CancellationError {
            return
        } catch {
            pauseFinderQueueRecovery(
                for: error,
                title: "无法恢复 Finder 操作"
            )
        }
    }

    private func processFinderCommand(
        id requestID: UUID,
        waitForAgentHandoff: Bool = false
    ) async {
        guard let coordinator = finderQueueCoordinator else { return }
        guard !rejectedFinderCommandIDs.contains(requestID) else { return }
        guard processingFinderCommandIDs.insert(requestID).inserted else { return }
        defer { processingFinderCommandIDs.remove(requestID) }

        // Finder routes mutate the app's shared selection state. MainActor
        // prevents simultaneous instructions, but it is re-entrant across
        // `await`, so a separate gate is required to keep different requests
        // from switching roots underneath one another.
        while activeFinderCommandID != nil
            || activeOperation != nil
            || !finalizingFinderCommandIDs.isEmpty
            || hasBlockingPresentation {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
        activeFinderCommandID = requestID
        defer {
            if activeFinderCommandID == requestID {
                activeFinderCommandID = nil
            }
        }

        let claimed: FinderCommandClaim
        do {
            guard let result = try await claimFinderCommand(
                id: requestID,
                waitForAgentHandoff: waitForAgentHandoff
            ) else { return }
            claimed = result
        } catch is CancellationError {
            return
        } catch {
            rejectedFinderCommandIDs.insert(requestID)
            present(error, title: "无法读取 Finder 操作")
            return
        }

        let command = claimed.command
        do {
            try Task.checkCancellation()
            try validateFinderCommand(command)
        } catch is CancellationError {
            _ = await acknowledgeFinderClaim(claimed, outcome: .cancelled)
            return
        } catch {
            rejectedFinderCommandIDs.insert(requestID)
            if await acknowledgeFinderClaim(claimed, outcome: .rejected) {
                present(error, title: "无法处理 Finder 操作")
            }
            return
        }

        let commandAge = Date().timeIntervalSince(command.createdAt)
        guard commandAge <= 5 * 60, commandAge >= -60 else {
            rejectedFinderCommandIDs.insert(requestID)
            if await acknowledgeFinderClaim(claimed, outcome: .rejected) {
                present(
                    SvnDockServiceError.unavailable(
                        commandAge > 5 * 60
                            ? "这个 Finder 操作已经过期，请重新执行。"
                            : "这个 Finder 操作的创建时间无效，请重新执行。"
                    ),
                    title: commandAge > 5 * 60 ? "操作已过期" : "操作时间无效"
                )
            }
            return
        }

        if Self.finderCommandRequiresUserInteraction(command.kind) {
            let awaitingClaim: FinderCommandClaim
            do {
                awaitingClaim = try await coordinator.markAwaitingUser(claimed)
            } catch {
                rejectedFinderCommandIDs.insert(requestID)
                if await acknowledgeFinderClaim(claimed, outcome: .rejected) {
                    present(error, title: "无法准备 Finder 操作")
                }
                return
            }

            do {
                try await routeFinderCommand(command, interactiveClaim: awaitingClaim)
            } catch is CancellationError {
                _ = await acknowledgeFinderClaim(awaitingClaim, outcome: .cancelled)
            } catch {
                rejectedFinderCommandIDs.insert(requestID)
                if await acknowledgeFinderClaim(awaitingClaim, outcome: .rejected) {
                    presentFinderRoutingError(error)
                }
            }
            return
        }

        let executingClaim: FinderCommandClaim
        do {
            executingClaim = try await coordinator.markExecuting(claimed)
        } catch {
            rejectedFinderCommandIDs.insert(requestID)
            if await acknowledgeFinderClaim(claimed, outcome: .rejected) {
                present(error, title: "无法开始 Finder 操作")
            }
            return
        }

        do {
            try await routeFinderCommand(command)
            try Task.checkCancellation()
        } catch is CancellationError {
            await quarantineExecutedFinderClaim(executingClaim)
            return
        } catch {
            await quarantineExecutedFinderClaim(executingClaim)
            presentFinderRoutingError(error)
            return
        }

        _ = await acknowledgeFinderClaim(executingClaim, outcome: .completed)
    }

    @discardableResult
    func loadDiffForSelection(
        allowDuringFinderRouting: Bool = false
    ) async -> Bool {
        if !allowDuringFinderRouting,
           !(await waitForFinderRoutingToFinish()) {
            return false
        }
        guard !Task.isCancelled else { return false }
        clearDiff()
        let generation = UUID()
        diffLoadGeneration = generation
        guard
            selectedEntryIDs.count == 1,
            let workingCopy = selectedWorkingCopy,
            let entry = primarySelectedEntry,
            entry.status != .unversioned,
            entry.status != .ignored,
            entry.status != .missing
        else {
            diffText = ""
            isLoadingDiff = false
            return false
        }

        let expectedEntryID = entry.id
        isLoadingDiff = true
        diffText = ""
        defer {
            if diffLoadGeneration == generation {
                isLoadingDiff = false
                diffLoadTask = nil
            }
        }

        func isCurrentRequest() -> Bool {
            !Task.isCancelled && diffLoadGeneration == generation
                && selectedWorkingCopyID == workingCopy.id
                && selectedEntryIDs.count == 1
                && primarySelectedEntry?.id == expectedEntryID
        }

        do {
            let service = service
            let task = Task {
                try await service.diff(relativePath: entry.relativePath, in: workingCopy)
            }
            diffLoadTask = task
            let loadedDiff = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard isCurrentRequest() else { return false }
            diffText = loadedDiff
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrentRequest() else { return false }
            diffText = ""
            diffLoadError = error.localizedDescription
            return false
        }
    }

    private func clearDiff() {
        diffLoadTask?.cancel()
        diffLoadTask = nil
        diffLoadGeneration = UUID()
        diffLoadError = nil
        if !diffText.isEmpty { diffText = "" }
        if isLoadingDiff { isLoadingDiff = false }
    }

    func diffText(for request: SvnDockDiffRequest) async throws -> String {
        guard let workingCopy = workingCopies.first(where: {
            $0.id == request.workingCopyID
        }) else {
            throw SvnDockServiceError.unavailable(
                "该工作副本已不在 SvnDock 的登记列表中。"
            )
        }
        return try await service.diff(
            relativePath: request.relativePath,
            in: workingCopy
        )
    }

    func revisionDetails(for request: SvnDockRevisionRequest) async throws -> SVNRevisionDetails {
        guard let copy = workingCopies.first(where: { $0.id == request.workingCopyID }) else {
            throw SvnDockServiceError.unavailable("该工作副本已不在登记列表中。")
        }
        return try await service.revisionDetails(revision: request.revision, in: copy)
    }

    func revisionDiff(for request: SvnDockRevisionRequest, change: SVNChangedPath,
                      repositoryRoot: URL) async throws -> String {
        guard let copy = workingCopies.first(where: { $0.id == request.workingCopyID }) else {
            throw SvnDockServiceError.unavailable("该工作副本已不在登记列表中。")
        }
        return try await service.revisionDiff(revision: request.revision, change: change,
                                              repositoryRoot: repositoryRoot, in: copy)
    }

    func showHistoryForSelection(
        allowDuringFinderRouting: Bool = false
    ) async {
        guard let workingCopy = selectedWorkingCopy else {
            clearHistory()
            return
        }
        guard selectedEntryIDs.count <= 1 else {
            clearHistory()
            historyErrorMessage = "一次只能查看一个项目的提交历史。"
            inspectorTab = .history
            return
        }

        if let entry = primarySelectedEntry {
            await showHistory(
                for: workingCopy,
                relativePaths: [entry.relativePath],
                title: entry.fileName,
                source: .selection,
                allowDuringFinderRouting: allowDuringFinderRouting
            )
        } else {
            await showHistory(
                for: workingCopy,
                relativePaths: [],
                title: workingCopy.name,
                source: .selection,
                allowDuringFinderRouting: allowDuringFinderRouting
            )
        }
    }

    func showHistory(for workingCopy: SvnDockWorkingCopy) async {
        guard await waitForFinderRoutingToFinish() else { return }
        if selectedWorkingCopyID != workingCopy.id {
            clearHistory()
            clearStatusEntries()
            selectedEntryIDs = []
            diffText = ""
            suppressedSelectionReloadID = workingCopy.id
            selectedWorkingCopyID = workingCopy.id
            await reloadSelectedWorkingCopy()
        }
        guard selectedWorkingCopyID == workingCopy.id else { return }
        // A sidebar/root-history action is explicit and must not inherit a
        // stale file selection from the diff or information inspector.
        selectedEntryIDs = []
        await showHistory(
            for: workingCopy,
            relativePaths: [],
            title: workingCopy.name,
            source: .workingCopy,
            allowDuringFinderRouting: false
        )
    }

    func ensureHistoryForSelection() async {
        guard inspectorTab == .history,
              let workingCopy = selectedWorkingCopy else { return }

        if historyNeedsReload,
           let target = historyTarget,
           target.workingCopy.id == workingCopy.id,
           historyTargetMatchesCurrentSelection(target) {
            await loadHistory(target: target, limit: historyLimit)
            return
        }

        // Explicit Finder and sidebar targets can have no corresponding
        // changed status row. Preserve only those sources while selection is
        // empty; a normal selection target should return to WC history when
        // the user clears the row selection.
        if selectedEntryIDs.isEmpty,
           historyTarget?.workingCopy.id == workingCopy.id,
           historyTarget?.source != .selection {
            return
        }
        await showHistoryForSelection()
    }

    private func historyTargetMatchesCurrentSelection(
        _ target: SvnDockHistoryTarget
    ) -> Bool {
        guard selectedEntryIDs.count <= 1 else { return false }

        switch target.source {
        case .selection:
            if selectedEntryIDs.isEmpty {
                return target.relativePaths.isEmpty
            }
            guard let entry = primarySelectedEntry else { return false }
            return target.relativePaths == [entry.relativePath]
        case .finderExplicit, .workingCopy:
            return selectedEntryIDs.isEmpty
        }
    }

    func refreshHistory() async {
        guard let target = historyTarget else {
            await showHistoryForSelection()
            return
        }
        await loadHistory(target: target, limit: historyLimit)
    }

    func loadMoreHistory() async {
        guard let target = historyTarget, canLoadMoreHistory else { return }
        await loadHistory(
            target: target,
            limit: min(historyLimit + 100, 1_000)
        )
    }

    private func showHistory(
        for workingCopy: SvnDockWorkingCopy,
        relativePaths: [String],
        title: String,
        source: SvnDockHistoryTargetSource,
        allowDuringFinderRouting: Bool
    ) async {
        if !allowDuringFinderRouting,
           !(await waitForFinderRoutingToFinish()) {
            return
        }
        let target = SvnDockHistoryTarget(
            workingCopy: workingCopy,
            relativePaths: relativePaths,
            title: title,
            source: source
        )
        inspectorTab = .history
        // The routing/presentation gate was checked above. Skip the duplicate
        // asynchronous wait so the target and task are published before
        // SwiftUI can launch InspectorView's task for the newly selected tab.
        await loadHistory(
            target: target,
            limit: 100,
            allowDuringFinderRouting: true
        )
    }

    private func loadHistory(
        target: SvnDockHistoryTarget,
        limit: Int,
        allowDuringFinderRouting: Bool = false
    ) async {
        if !allowDuringFinderRouting,
           !(await waitForFinderRoutingToFinish()) {
            return
        }
        if isLoadingHistory,
           historyTarget?.id == target.id,
           historyLimit == limit,
           let existingTask = historyLoadTask {
            let existingGeneration = historyLoadGeneration
            await existingTask.value
            guard !Task.isCancelled else { return }

            // Inspector task replacement can cancel the shared request just
            // before a new task asks for the same target. A completed request
            // (including a valid empty history) is reusable; a cancelled one
            // must be restarted if nobody else has already taken ownership.
            guard existingTask.isCancelled else { return }
            guard historyLoadGeneration == existingGeneration,
                  historyTarget?.id == target.id,
                  historyLimit == limit,
                  !isLoadingHistory else { return }
        }

        historyLoadTask?.cancel()
        let generation = UUID()
        historyLoadGeneration = generation
        historyNeedsReload = false
        historyTarget = target
        historyLimit = limit
        historyEntries = []
        historyErrorMessage = nil
        isLoadingHistory = true

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performHistoryLoad(
                target: target,
                limit: limit,
                generation: generation
            )
        }
        historyLoadTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performHistoryLoad(
        target: SvnDockHistoryTarget,
        limit: Int,
        generation: UUID
    ) async {
        do {
            let loaded = try await service.history(
                for: target.workingCopy,
                relativePaths: target.relativePaths,
                limit: limit
            )
            guard historyLoadGeneration == generation,
                  historyTarget?.id == target.id else { return }
            historyEntries = loaded
            isLoadingHistory = false
            historyLoadTask = nil
            historyNeedsReload = false
        } catch is CancellationError {
            guard historyLoadGeneration == generation else { return }
            isLoadingHistory = false
            historyLoadTask = nil
            historyNeedsReload = true
        } catch {
            guard historyLoadGeneration == generation,
                  historyTarget?.id == target.id else { return }
            historyEntries = []
            historyErrorMessage = error.localizedDescription
            isLoadingHistory = false
            historyLoadTask = nil
            historyNeedsReload = false
        }
    }

    private func cancelHiddenHistoryLoad() {
        guard let task = historyLoadTask else { return }
        historyLoadTask = nil
        historyLoadGeneration = nil
        historyNeedsReload = true
        isLoadingHistory = false
        task.cancel()
    }

    private func clearHistory() {
        historyLoadTask?.cancel()
        historyLoadTask = nil
        historyLoadGeneration = nil
        historyNeedsReload = false
        historyTarget = nil
        historyEntries = []
        historyLimit = 100
        historyErrorMessage = nil
        isLoadingHistory = false
    }

    @discardableResult
    private func perform(
        kind: SvnDockOperationKind,
        detail: String? = nil,
        allowDuringFinderRouting: Bool = false,
        operation: @MainActor () async throws -> Void
    ) async -> Bool {
        while activeOperation != nil
            || (!allowDuringFinderRouting && (
                activeFinderCommandID != nil
                    || hasBlockingPresentation
            )) {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        activeOperation = SvnDockOperationState(kind: kind, detail: detail)
        defer { activeOperation = nil }

        do {
            try await operation()
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error, title: operationFailureTitle(for: kind))
            return false
        }
    }

    func showMoreStatusEntries() {
        guard hasMoreFilteredEntries else { return }
        visibleEntryLimit = min(
            visibleEntryLimit + Self.visibleEntryBatchSize,
            filteredEntryCount
        )
        displayedEntries = Array(filteredStatusEntries.prefix(visibleEntryLimit))
    }

    func selectAllFilteredStatusEntries() {
        guard !isFilteringStatusEntries else { return }
        var entryIDs = Set<SvnDockStatusEntry.ID>()
        entryIDs.reserveCapacity(filteredStatusEntries.count)
        for entry in filteredStatusEntries {
            entryIDs.insert(entry.id)
        }
        selectedEntryIDs = entryIDs
    }

    func canExpandDirectory(_ entry: SvnDockStatusEntry) -> Bool {
        entry.nodeKind == .directory
            && !entry.isSymbolicLink
            && (entry.status == .unversioned || entry.status == .added)
    }

    func isDirectoryExpanded(_ entry: SvnDockStatusEntry) -> Bool {
        expandedDirectoryIDs.contains(entry.id)
    }

    func isLoadingDirectory(_ entry: SvnDockStatusEntry) -> Bool {
        loadingDirectoryIDs.contains(entry.id)
    }

    func directoryError(for entry: SvnDockStatusEntry) -> String? {
        directoryErrorsByID[entry.id]
    }

    func visibleDirectoryChildren(
        for entry: SvnDockStatusEntry
    ) -> [SvnDockStatusEntry] {
        let children = directoryChildrenByID[entry.id, default: []]
        let limit = directoryVisibleLimits[
            entry.id,
            default: Self.initialDirectoryChildLimit
        ]
        return Array(children.prefix(limit))
    }

    func hasMoreDirectoryChildren(for entry: SvnDockStatusEntry) -> Bool {
        directoryVisibleLimits[entry.id, default: Self.initialDirectoryChildLimit]
            < directoryChildrenByID[entry.id, default: []].count
    }

    func remainingDirectoryChildCount(for entry: SvnDockStatusEntry) -> Int {
        let total = directoryChildrenByID[entry.id, default: []].count
        let visible = directoryVisibleLimits[entry.id, default: Self.initialDirectoryChildLimit]
        return min(Self.directoryChildBatchSize, max(0, total - visible))
    }

    func toggleDirectoryExpansion(for entry: SvnDockStatusEntry) {
        guard canExpandDirectory(entry),
              entry.workingCopyID == selectedWorkingCopyID else { return }

        if expandedDirectoryIDs.remove(entry.id) != nil {
            return
        }

        expandedDirectoryIDs.insert(entry.id)
        if directoryChildrenByID[entry.id] == nil,
           !loadingDirectoryIDs.contains(entry.id) {
            startLoadingDirectory(entry)
        }
    }

    func retryDirectoryLoad(for entry: SvnDockStatusEntry) {
        guard canExpandDirectory(entry),
              entry.workingCopyID == selectedWorkingCopyID else { return }
        directoryLoadTasks[entry.id]?.cancel()
        directoryChildrenByID[entry.id] = nil
        directoryErrorsByID[entry.id] = nil
        expandedDirectoryIDs.insert(entry.id)
        startLoadingDirectory(entry)
    }

    func showMoreDirectoryChildren(for entry: SvnDockStatusEntry) {
        let current = directoryVisibleLimits[
            entry.id,
            default: Self.initialDirectoryChildLimit
        ]
        let total = directoryChildrenByID[entry.id, default: []].count
        directoryVisibleLimits[entry.id] = min(
            current + Self.directoryChildBatchSize,
            total
        )
    }

    private func startLoadingDirectory(_ entry: SvnDockStatusEntry) {
        guard let workingCopy = workingCopies.first(where: {
            $0.id == entry.workingCopyID
        }) else { return }

        let generation = UUID()
        directoryLoadGenerations[entry.id] = generation
        directoryErrorsByID[entry.id] = nil
        loadingDirectoryIDs.insert(entry.id)
        directoryVisibleLimits[entry.id] = Self.initialDirectoryChildLimit

        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadDirectoryChildren(
                of: entry,
                in: workingCopy,
                generation: generation
            )
        }
        directoryLoadTasks[entry.id] = task
    }

    private func loadDirectoryChildren(
        of entry: SvnDockStatusEntry,
        in workingCopy: SvnDockWorkingCopy,
        generation: UUID
    ) async {
        defer {
            if directoryLoadGenerations[entry.id] == generation {
                loadingDirectoryIDs.remove(entry.id)
                directoryLoadTasks[entry.id] = nil
                directoryLoadGenerations[entry.id] = nil
            }
        }
        do {
            let loadedChildren = try await service.directoryChildren(
                relativePath: entry.relativePath,
                in: workingCopy
            )
            try Task.checkCancellation()
            guard directoryLoadGenerations[entry.id] == generation,
                  selectedWorkingCopyID == workingCopy.id else { return }

            if let previousChildren = directoryChildrenByID[entry.id] {
                for child in previousChildren {
                    discoveredEntryIndex[child.id] = nil
                }
            }
            let children = loadedChildren.map { child in
                statusSnapshot.entry(withID: child.id) ?? child
            }
            for child in children {
                discoveredEntryIndex[child.id] = child
            }
            directoryChildrenByID[entry.id] = children
            directoryErrorsByID[entry.id] = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  directoryLoadGenerations[entry.id] == generation,
                  selectedWorkingCopyID == workingCopy.id else { return }
            directoryErrorsByID[entry.id] = error.localizedDescription
        }
    }

    private func resetDirectoryTree() {
        for task in directoryLoadTasks.values {
            task.cancel()
        }
        directoryLoadTasks = [:]
        directoryLoadGenerations = [:]
        discoveredEntryIndex = [:]
        expandedDirectoryIDs = []
        directoryChildrenByID = [:]
        loadingDirectoryIDs = []
        directoryErrorsByID = [:]
        directoryVisibleLimits = [:]
    }

    private func statusEntry(
        withID id: SvnDockStatusEntry.ID
    ) -> SvnDockStatusEntry? {
        statusSnapshot.entry(withID: id) ?? discoveredEntryIndex[id]
    }

    private func selectedStatusEntries(
        where predicate: (SvnDockStatusEntry) -> Bool
    ) -> [SvnDockStatusEntry] {
        selectedEntryIDs
            .compactMap(statusEntry(withID:))
            .filter(predicate)
            .sorted { $0.relativePath < $1.relativePath }
    }

    private func apply(
        _ loadedSnapshot: SvnDockStatusSnapshot,
        to workingCopyID: UUID
    ) {
        resetDirectoryTree()
        statusSnapshot = loadedSnapshot
        selectedEntryIDs = Set(selectedEntryIDs.filter {
            loadedSnapshot.containsEntry(withID: $0)
        })
        filteredStatusEntries = []
        filteredEntryCount = 0
        displayedEntries = []
        rebuildStatusPresentation(resetLimit: true, debounce: false)

        guard let index = workingCopies.firstIndex(where: { $0.id == workingCopyID }) else { return }
        workingCopies[index].counts = loadedSnapshot.counts
        workingCopies[index].lastRefreshedAt = .now
    }

    private func clearStatusEntries() {
        clearDiff()
        resetDirectoryTree()
        activeStatusLoadTask?.cancel()
        activeStatusLoadTask = nil
        statusLoadGeneration = UUID()
        statusPresentationTask?.cancel()
        statusPresentationTask = nil
        statusPresentationGeneration = UUID()
        statusSnapshot = .empty
        filteredStatusEntries = []
        visibleEntryLimit = Self.initialVisibleEntryLimit
        filteredEntryCount = 0
        displayedEntries = []
        isFilteringStatusEntries = false
    }

    private func loadStatusSnapshot(
        for workingCopy: SvnDockWorkingCopy
    ) async throws -> SvnDockStatusSnapshot {
        activeStatusLoadTask?.cancel()
        let generation = UUID()
        statusLoadGeneration = generation
        let service = service
        let task = Task {
            try await service.status(for: workingCopy)
        }
        activeStatusLoadTask = task

        defer {
            if statusLoadGeneration == generation {
                activeStatusLoadTask = nil
            }
        }

        let snapshot = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard statusLoadGeneration == generation else {
            throw CancellationError()
        }
        return snapshot
    }

    private func rebuildStatusPresentation(resetLimit: Bool, debounce: Bool) {
        statusPresentationTask?.cancel()
        statusPresentationTask = nil
        let generation = UUID()
        statusPresentationGeneration = generation

        if resetLimit {
            visibleEntryLimit = Self.initialVisibleEntryLimit
        }

        let normalizedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = statusFilter
        let sourceEntries = showsMissingDetails || !normalizedQuery.isEmpty
            ? statusSnapshot.entries : statusSnapshot.groupedEntries

        if filter == .all, normalizedQuery.isEmpty {
            applyFilteredStatusEntries(sourceEntries, generation: generation)
            return
        }

        isFilteringStatusEntries = true
        statusPresentationTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                if debounce {
                    try await Task.sleep(for: .milliseconds(200))
                }

                var matchingEntries: [SvnDockStatusEntry] = []
                matchingEntries.reserveCapacity(min(sourceEntries.count, 1_000))
                for (index, entry) in sourceEntries.enumerated() {
                    if index.isMultiple(of: 256) {
                        try Task.checkCancellation()
                    }
                    guard filter.includes(entry) else { continue }
                    if normalizedQuery.isEmpty
                        || entry.relativePath.localizedStandardContains(normalizedQuery)
                        || entry.status.displayName.localizedStandardContains(normalizedQuery) {
                        matchingEntries.append(entry)
                    }
                }
                try Task.checkCancellation()
                await self?.applyFilteredStatusEntries(
                    matchingEntries,
                    generation: generation
                )
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func applyFilteredStatusEntries(
        _ entries: [SvnDockStatusEntry],
        generation: UUID
    ) {
        guard statusPresentationGeneration == generation else { return }
        filteredStatusEntries = entries
        filteredEntryCount = entries.count
        displayedEntries = Array(entries.prefix(visibleEntryLimit))
        isFilteringStatusEntries = false
        statusPresentationTask = nil
    }

    private func present(_ error: Error, title: String) {
        presentedError = SvnDockUserFacingError(title: title, message: error.localizedDescription)
    }

    private func operationFailureTitle(for kind: SvnDockOperationKind) -> String {
        switch kind {
        case .loading: "载入失败"
        case .refreshing: "刷新失败"
        case .checkingRemote: "检查服务器失败"
        case .updating: "更新失败"
        case .committing: "提交失败"
        case .adding: "添加失败"
        case .unschedulingAdd: "取消添加失败"
        case .deleting: "标记删除失败"
        case .reverting: "还原失败"
        case .cleaning: "清理失败"
        case .resolving: "解决冲突失败"
        case .ignoring: "添加忽略规则失败"
        }
    }

    private static func copySort(_ lhs: SvnDockWorkingCopy, _ rhs: SvnDockWorkingCopy) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func claimFinderCommand(
        id: UUID,
        waitForAgentHandoff: Bool
    ) async throws -> FinderCommandClaim? {
        guard let coordinator = finderQueueCoordinator else { return nil }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))

        while true {
            try Task.checkCancellation()
            if let claim = try await coordinator.claimCommand(id: id, as: .application) {
                return claim
            }

            let location = try await coordinator.location(of: id)
            switch location {
            case .processing(owner: .agent, phase: let phase):
                guard waitForAgentHandoff,
                      phase != .executing,
                      clock.now < deadline else { return nil }
                // The Agent first owns the file, then publishes an interactive
                // request to command-app-inbox. Observe durable state rather
                // than assuming the handoff completes within a fixed attempt.
                try await Task.sleep(for: .milliseconds(80))
            case .pending, .applicationInbox:
                guard clock.now < deadline else { return nil }
                // A rename may have raced the failed claim. Re-read the state
                // on the next turn; another App claimant will become visible
                // as application processing.
                await Task.yield()
            case .processing, .completed, .uncertain, .absent:
                return nil
            }
        }
    }

    private func markFinderClaimExecuting(
        _ claim: FinderCommandClaim?
    ) async throws -> FinderCommandClaim? {
        guard let claim else { return nil }
        guard let coordinator = finderQueueCoordinator else {
            throw SvnDockServiceError.unavailable("Finder 队列协调器不可用。")
        }
        return try await coordinator.markExecuting(claim)
    }

    /// Returns true once the command has a durable terminal receipt. If the
    /// receipt write succeeded but claim cleanup failed, `location` still
    /// reports completed and startup recovery will finish that cleanup.
    private func acknowledgeFinderClaim(
        _ claim: FinderCommandClaim,
        outcome: FinderCommandReceiptOutcome
    ) async -> Bool {
        guard let coordinator = finderQueueCoordinator else { return false }
        do {
            try await coordinator.acknowledge(claim, outcome: outcome)
            return true
        } catch {
            if (try? await coordinator.hasMatchingReceipt(
                for: claim,
                outcome: outcome
            )) == true {
                return true
            }

            // Never release a command after an ambiguous terminal write. A
            // non-executing claim is also quarantined here so a cancellation
            // cannot unexpectedly reappear after the next launch.
            try? await coordinator.quarantine(claim)
            pauseFinderQueueRecovery(
                for: error,
                title: "无法保存 Finder 操作结果"
            )
            return false
        }
    }

    private func quarantineExecutedFinderClaim(_ claim: FinderCommandClaim) async {
        guard let coordinator = finderQueueCoordinator else { return }
        do {
            try await coordinator.quarantine(claim)
        } catch {
            if let location = try? await coordinator.location(of: claim.command.id) {
                switch location {
                case .uncertain, .completed:
                    return
                default:
                    break
                }
            }
            pauseFinderQueueRecovery(
                for: error,
                title: "无法隔离未确认的 Finder 操作"
            )
        }
    }

    /// UI cancellation entry points are synchronous. Publish the finalization
    /// gate before starting asynchronous receipt I/O so the next Finder item
    /// cannot replace the selection in the intervening MainActor turn.
    private func finalizeAwaitingFinderClaim(
        _ claim: FinderCommandClaim?,
        outcome: FinderCommandReceiptOutcome
    ) {
        guard let claim,
              finalizingFinderCommandIDs.insert(claim.command.id).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.acknowledgeFinderClaim(claim, outcome: outcome)
            self.finalizingFinderCommandIDs.remove(claim.command.id)
            await self.processPendingFinderCommands()
        }
    }

    private func pauseFinderQueueRecovery(for error: Error, title: String) {
        isFinderQueueRecoveryPaused = true
        let recoveryError = SvnDockUserFacingError(
            title: title,
            message: error.localizedDescription
        )
        finderQueueRecoveryErrorID = recoveryError.id
        presentedError = recoveryError
    }

    private func presentFinderRoutingError(_ error: Error) {
        if error is FinderCommandRouteError { return }
        present(error, title: "无法处理 Finder 操作")
    }

    private static func finderCommandRequiresUserInteraction(
        _ kind: FinderCommandKind
    ) -> Bool {
        switch kind {
        case .commit, .revert, .resolve, .ignoreName, .ignoreExtension:
            true
        case .openApp, .refresh, .update, .diff, .add, .cleanup, .log,
             .copyRepositoryURL:
            false
        }
    }

    private func waitForFinderRoutingToFinish() async -> Bool {
        while activeFinderCommandID != nil
            || !finalizingFinderCommandIDs.isEmpty
            || hasBlockingPresentation {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        return true
    }

    private func routeFinderCommand(
        _ command: FinderCommand,
        interactiveClaim: FinderCommandClaim? = nil
    ) async throws {
        let workingCopy = try await selectWorkingCopy(forRootPath: command.workingCopyRoot)
        selectEntries(forAbsolutePaths: command.paths, in: workingCopy)

        switch command.kind {
        case .openApp:
            break
        case .refresh:
            // `selectWorkingCopy` has already reloaded authoritative status
            // and rewritten the Finder badge snapshot.
            break
        case .update:
            let succeeded = await update(
                workingCopyIDs: [workingCopy.id],
                allowDuringFinderRouting: true
            )
            try Task.checkCancellation()
            guard succeeded else { throw FinderCommandRouteError.alreadyReported }
        case .commit:
            guard let interactiveClaim else {
                throw SvnDockServiceError.unavailable("Finder 提交缺少交互式队列声明。")
            }
            let selectedRoot = command.paths.count == 1
                && URL(fileURLWithPath: command.paths[0]).standardizedFileURL
                    == workingCopy.rootURL.standardizedFileURL
            let selectedCommittable = entries.contains {
                selectedEntryIDs.contains($0.id) && $0.status.canCommit
            }
            guard !committableEntries.isEmpty,
                  selectedRoot || selectedCommittable else {
                throw SvnDockServiceError.unavailable(
                    "所选文件已经没有可提交的本地更改，请刷新后重试。"
                )
            }
            requestCommit(
                allowDuringFinderRouting: true,
                finderClaim: interactiveClaim
            )
            guard isPresentingCommit else {
                throw FinderCommandRouteError.alreadyReported
            }
        case .diff:
            guard command.paths.count == 1,
                  let entry = primarySelectedEntry,
                  entry.nodeKind == .file,
                  entry.status != .unversioned,
                  entry.status != .ignored,
                  let selectedPath = command.paths.first.map({
                      URL(fileURLWithPath: $0).standardizedFileURL.path
                  }),
                  workingCopy.rootURL
                    .appendingPathComponent(entry.relativePath)
                    .standardizedFileURL.path == selectedPath else {
                throw SvnDockServiceError.unavailable("所选文件已经无法查看差异。")
            }
            inspectorTab = .diff
            let succeeded = await loadDiffForSelection(allowDuringFinderRouting: true)
            try Task.checkCancellation()
            guard succeeded else { throw FinderCommandRouteError.alreadyReported }
        case .add:
            guard entries.contains(where: {
                selectedEntryIDs.contains($0.id) && $0.status == .unversioned
            }) else {
                throw SvnDockServiceError.unavailable("所选文件已经不再是未纳管状态。")
            }
            let succeeded = await addSelectedEntries(
                allowDuringFinderRouting: true
            )
            try Task.checkCancellation()
            guard succeeded else { throw FinderCommandRouteError.alreadyReported }
        case .revert:
            guard let interactiveClaim else {
                throw SvnDockServiceError.unavailable("Finder 还原缺少交互式队列声明。")
            }
            let selectedChanges = entries.filter {
                selectedEntryIDs.contains($0.id) && $0.status.isChange
            }
            guard !selectedChanges.isEmpty else {
                throw SvnDockServiceError.unavailable("所选文件已经没有可还原的本地更改。")
            }
            if selectedChanges.allSatisfy({ $0.status == .added }) {
                requestUnscheduleAddConfirmation(
                    allowDuringFinderRouting: true,
                    finderClaim: interactiveClaim
                )
                guard isPresentingUnscheduleAddConfirmation else {
                    throw FinderCommandRouteError.alreadyReported
                }
            } else if selectedChanges.contains(where: { $0.status == .added }) {
                throw SvnDockServiceError.unavailable(
                    "请将待添加项目与其他本地更改分开还原，以免误操作文件内容。"
                )
            } else {
                requestRevertConfirmation(
                    allowDuringFinderRouting: true,
                    finderClaim: interactiveClaim
                )
                guard isPresentingRevertConfirmation else {
                    throw FinderCommandRouteError.alreadyReported
                }
            }
        case .cleanup:
            let succeeded = await cleanupSelectedWorkingCopy(
                allowDuringFinderRouting: true
            )
            try Task.checkCancellation()
            guard succeeded else { throw FinderCommandRouteError.alreadyReported }
        case .copyRepositoryURL:
            guard let repositoryURL = workingCopy.repositoryURL?.absoluteString else {
                throw SvnDockServiceError.unavailable("无法读取这个工作副本的仓库地址。")
            }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(repositoryURL, forType: .string) else {
                throw SvnDockServiceError.unavailable("无法将仓库地址写入剪贴板。")
            }
        case .log:
            guard command.paths.count == 1,
                  let selectedURL = command.paths.first.map({
                      URL(fileURLWithPath: $0).standardizedFileURL
                  }),
                  let relativePath = Self.relativePath(
                      for: selectedURL,
                      under: workingCopy.rootURL
                  ) else {
                throw SvnDockServiceError.unavailable("一次只能查看一个项目的提交历史。")
            }
            if let entry = exactEntry(for: selectedURL, in: workingCopy),
               entry.status == .unversioned || entry.status == .ignored {
                throw SvnDockServiceError.unavailable("未纳管或已忽略的项目没有 SVN 提交历史。")
            }
            // Finder supplied an explicit history target. A directory may
            // contain many changed status rows, but those rows must not cause
            // InspectorView's selection task to replace the requested target.
            selectedEntryIDs = []
            let isRoot = relativePath == "."
            await showHistory(
                for: workingCopy,
                relativePaths: isRoot ? [] : [relativePath],
                title: isRoot ? workingCopy.name : selectedURL.lastPathComponent,
                source: .finderExplicit,
                allowDuringFinderRouting: true
            )
            try Task.checkCancellation()
            guard historyErrorMessage == nil, !historyNeedsReload else {
                throw FinderCommandRouteError.alreadyReported
            }
        case .resolve:
            guard let interactiveClaim else {
                throw SvnDockServiceError.unavailable("Finder 冲突处理缺少交互式队列声明。")
            }
            guard command.paths.count == 1,
                  let selectedURL = command.paths.first.map({
                      URL(fileURLWithPath: $0).standardizedFileURL
                  }),
                  let entry = exactEntry(for: selectedURL, in: workingCopy),
                  entry.status == .conflicted else {
                throw SvnDockServiceError.noConflictedFiles
            }
            selectedEntryIDs = [entry.id]
            requestResolveConfirmation(
                for: entry,
                allowDuringFinderRouting: true,
                finderClaim: interactiveClaim
            )
            guard isPresentingResolveConfirmation else {
                throw FinderCommandRouteError.alreadyReported
            }
        case .ignoreName, .ignoreExtension:
            guard let interactiveClaim else {
                throw SvnDockServiceError.unavailable("Finder 忽略操作缺少交互式队列声明。")
            }
            guard command.paths.count == 1,
                  let selectedURL = command.paths.first.map({
                      URL(fileURLWithPath: $0).standardizedFileURL
                  }),
                  let entry = exactEntry(for: selectedURL, in: workingCopy),
                  entry.status == .unversioned else {
                throw SvnDockServiceError.invalidIgnoreTarget(
                    "所选项目已经不再是未纳管状态。"
                )
            }
            selectedEntryIDs = [entry.id]
            requestIgnoreConfirmation(
                for: entry,
                mode: command.kind == .ignoreName ? .name : .fileExtension,
                allowDuringFinderRouting: true,
                finderClaim: interactiveClaim
            )
            guard isPresentingIgnoreConfirmation else {
                throw FinderCommandRouteError.alreadyReported
            }
        }
    }

    private func validateFinderCommand(_ command: FinderCommand) throws {
        guard command.source == "finder-extension" else {
            throw SvnDockServiceError.unavailable("Finder 请求来源无效。")
        }
        guard !command.paths.isEmpty, command.paths.count <= 4_096 else {
            throw SvnDockServiceError.unavailable("Finder 选择项目的数量无效。")
        }
        guard command.workingCopyRoot.hasPrefix("/"),
              !command.workingCopyRoot.contains("\0") else {
            throw SvnDockServiceError.unavailable("Finder 请求中的工作副本路径无效。")
        }

        let root = URL(
            fileURLWithPath: command.workingCopyRoot,
            isDirectory: true
        ).standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var seenPaths = Set<String>()

        for path in command.paths {
            guard path.hasPrefix("/"), !path.contains("\0") else {
                throw SvnDockServiceError.unavailable("Finder 请求包含无效路径。")
            }
            let selectedURL = URL(fileURLWithPath: path).standardizedFileURL
            guard Self.path(selectedURL.path, isInside: root.path) else {
                throw SvnDockServiceError.unavailable("Finder 所选项目不属于该工作副本。")
            }
            let resolvedURL = selectedURL.resolvingSymlinksInPath().standardizedFileURL
            guard Self.path(resolvedURL.path, isInside: resolvedRoot.path) else {
                throw SvnDockServiceError.unavailable("Finder 所选项目通过符号链接越出了工作副本。")
            }
            guard seenPaths.insert(selectedURL.path).inserted else {
                throw SvnDockServiceError.unavailable("Finder 请求包含重复路径。")
            }
        }
    }

    private static func path(_ candidate: String, isInside root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func relativePath(for url: URL, under root: URL) -> String? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        guard urlComponents.starts(with: rootComponents) else { return nil }
        let relative = urlComponents.dropFirst(rootComponents.count).joined(separator: "/")
        return relative.isEmpty ? "." : relative
    }

    private func exactEntry(
        for url: URL,
        in workingCopy: SvnDockWorkingCopy
    ) -> SvnDockStatusEntry? {
        entries.first { entry in
            workingCopy.rootURL
                .appendingPathComponent(entry.relativePath)
                .standardizedFileURL == url.standardizedFileURL
        }
    }

    private func selectWorkingCopy(forRootPath rootPath: String) async throws -> SvnDockWorkingCopy {
        let normalizedRoot = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        if !workingCopies.contains(where: { $0.rootURL.standardizedFileURL == normalizedRoot }) {
            workingCopies = try await service.loadRegisteredWorkingCopies().sorted(by: Self.copySort)
        }

        guard let workingCopy = workingCopies.first(where: {
            $0.rootURL.standardizedFileURL == normalizedRoot
        }) else {
            throw SvnDockServiceError.unavailable("这个工作副本已经不在 SvnDock 的登记列表中。")
        }

        if selectedWorkingCopyID != workingCopy.id {
            clearHistory()
            suppressedSelectionReloadID = workingCopy.id
            selectedWorkingCopyID = workingCopy.id
        }
        clearStatusEntries()
        selectedEntryIDs = []
        diffText = ""
        let loadedEntries = try await loadStatusSnapshot(for: workingCopy)
        guard selectedWorkingCopyID == workingCopy.id else {
            throw SvnDockServiceError.unavailable(
                "工作副本选择在 Finder 操作期间发生了变化，请重试。"
            )
        }
        apply(loadedEntries, to: workingCopy.id)
        return workingCopy
    }

    private func selectEntries(
        forAbsolutePaths paths: [String],
        in workingCopy: SvnDockWorkingCopy
    ) {
        let selectedPaths = Set(paths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
        selectedEntryIDs = Set(entries.compactMap { entry in
            let absolutePath = workingCopy.rootURL
                .appendingPathComponent(entry.relativePath)
                .standardizedFileURL.path
            return selectedPaths.contains(where: {
                Self.path(absolutePath, isInside: $0)
            }) ? entry.id : nil
        })
    }
}

private struct PendingCommitExecution: Sendable {
    let workingCopy: SvnDockWorkingCopy
    let relativePaths: [String]
    let message: String
    let finderClaim: FinderCommandClaim?
}

private struct PendingMissingDeletion: Sendable {
    let workingCopy: SvnDockWorkingCopy
    let relativePaths: [String]
}

private struct PendingUnscheduleAdd: Sendable {
    let workingCopy: SvnDockWorkingCopy
    let relativePaths: [String]
    let finderClaim: FinderCommandClaim?
    let missingOnly: Bool
}

private struct PendingRevert: Sendable {
    let workingCopy: SvnDockWorkingCopy
    let relativePaths: [String]
    let finderClaim: FinderCommandClaim?
}

private struct PendingResolve: Sendable {
    let workingCopy: SvnDockWorkingCopy
    let relativePaths: [String]
    let displayName: String
    let allowsFileReplacement: Bool
    let finderClaim: FinderCommandClaim?
}

private struct PendingIgnore: Sendable {
    let workingCopy: SvnDockWorkingCopy
    let rules: [SvnDockIgnoreRule]
    let message: String
    let finderClaim: FinderCommandClaim?
}

private enum FinderCommandRouteError: Error, Sendable {
    case alreadyReported
}
