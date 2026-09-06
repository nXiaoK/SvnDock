import Foundation
import SwiftUI
import SvnDockCore

@MainActor
final class HistoryRevisionModel: ObservableObject {
    typealias DetailsLoader = @Sendable (SvnDockRevisionRequest) async throws -> SVNRevisionDetails
    typealias DiffLoader = @Sendable (SvnDockRevisionRequest, SVNChangedPath, URL) async throws -> String

    @Published private(set) var details: SVNRevisionDetails?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedPath: String?
    @Published private(set) var diffText = ""
    @Published private(set) var isLoadingDiff = false
    @Published private(set) var diffErrorMessage: String?
    @Published private(set) var filteredChanges: [SVNChangedPath] = []
    @Published private(set) var visibleLimit = 300
    @Published private(set) var isFiltering = false
    @Published var pathQuery = "" {
        didSet { if pathQuery != oldValue { filterPaths() } }
    }

    private let detailsLoader: DetailsLoader
    private let diffLoader: DiffLoader
    private var request: SvnDockRevisionRequest?
    private var loadGeneration = UUID()
    private var diffGeneration = UUID()
    private var filterGeneration = UUID()
    private var diffTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var cache: [String: String] = [:]
    private var cacheOrder: [String] = []
    private var cacheBytes = 0

    init(detailsLoader: @escaping DetailsLoader, diffLoader: @escaping DiffLoader) {
        self.detailsLoader = detailsLoader
        self.diffLoader = diffLoader
    }

    deinit {
        diffTask?.cancel()
        filterTask?.cancel()
    }

    convenience init(store: SvnDockStore) {
        self.init(detailsLoader: { try await store.revisionDetails(for: $0) }, diffLoader: {
            try await store.revisionDiff(for: $0, change: $1, repositoryRoot: $2)
        })
    }

    var selectedChange: SVNChangedPath? {
        filteredChanges.first { $0.path == selectedPath }
    }
    var displayedChanges: ArraySlice<SVNChangedPath> { filteredChanges.prefix(visibleLimit) }
    var selectionIndex: Int? { filteredChanges.firstIndex { $0.path == selectedPath } }
    var preferredPathNotice: String? {
        guard selectedPath == nil, !isLoading, errorMessage == nil,
              let preferred = request?.preferredPath, let details else { return nil }
        if Self.preferredChange(in: details.changes, path: preferred) != nil {
            return "路径筛选隐藏了“\(preferred)”。请清除筛选或从变更列表中选择文件。"
        }
        return "此版本未列出“\(preferred)”，或存在多个可能的复制目标。文件可能使用了其他路径，请从本次提交的变更列表中选择。"
    }

    func load(_ request: SvnDockRevisionRequest) async {
        let previousPath = self.request == request ? selectedPath : nil
        cancel()
        let generation = UUID()
        loadGeneration = generation
        self.request = request
        details = nil
        filteredChanges = []
        selectedPath = nil
        diffText = ""
        errorMessage = nil
        diffErrorMessage = nil
        cache = [:]
        cacheOrder = []
        cacheBytes = 0
        isLoading = true
        do {
            let loaded = try await detailsLoader(request)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            guard loaded.entry.revision == request.revision else {
                throw SvnDockServiceError.unavailable("返回的提交版本与所选版本不一致，请刷新后重试。")
            }
            details = loaded
            isLoading = false
            filterPaths(preferredPath: previousPath ?? request.preferredPath, debounce: false)
            await filterTask?.value
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func select(_ path: String?, force: Bool = false) {
        guard force || selectedPath != path else { return }
        diffTask?.cancel()
        let generation = UUID()
        diffGeneration = generation
        selectedPath = path
        diffText = ""
        diffErrorMessage = nil
        isLoadingDiff = false
        guard let request, let details, let change = selectedChange else { return }
        if let index = selectionIndex, index >= visibleLimit { visibleLimit = index + 1 }
        if !force, let cached = cache[change.path] {
            cacheOrder.removeAll { $0 == change.path }
            cacheOrder.append(change.path)
            diffText = cached
            return
        }
        isLoadingDiff = true
        let loader = diffLoader
        let repositoryRoot = details.repositoryRootURL
        diffTask = Task { [weak self] in
            do {
                let text = try await loader(request, change, repositoryRoot)
                guard let self, !Task.isCancelled, self.diffGeneration == generation else { return }
                self.diffText = text
                self.isLoadingDiff = false
                self.remember(text, for: change.path)
            } catch {
                guard let self, !Task.isCancelled, self.diffGeneration == generation else { return }
                self.isLoadingDiff = false
                self.diffErrorMessage = error.localizedDescription
            }
        }
    }

    func moveSelection(by delta: Int) {
        guard let index = selectionIndex,
              filteredChanges.indices.contains(index + delta) else { return }
        select(filteredChanges[index + delta].path)
    }

    func showMore() { visibleLimit += 300 }

    func cancel() {
        loadGeneration = UUID()
        diffGeneration = UUID()
        filterGeneration = UUID()
        diffTask?.cancel()
        filterTask?.cancel()
        diffTask = nil
        filterTask = nil
        isLoading = false
        isLoadingDiff = false
        isFiltering = false
    }

    private func filterPaths(preferredPath: String? = nil, debounce: Bool = true) {
        filterTask?.cancel()
        let generation = UUID()
        filterGeneration = generation
        let query = pathQuery
        let changes = details?.changes ?? []
        let preferred = preferredPath ?? request?.preferredPath
        isFiltering = true
        filterTask = Task { [weak self] in
            if debounce {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                try Self.matching(changes, query: query)
            }
            let matches: [SVNChangedPath]
            do {
                matches = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
            } catch { return }
            guard let self, !Task.isCancelled, self.filterGeneration == generation else { return }
            self.filteredChanges = matches
            self.visibleLimit = 300
            self.isFiltering = false
            if !matches.contains(where: { $0.path == self.selectedPath }) {
                let selection: SVNChangedPath?
                if let preferred {
                    selection = Self.preferredChange(in: matches, path: preferred)
                } else {
                    selection = matches.first { $0.kind != .directory } ?? matches.first
                }
                self.select(selection?.path)
            } else if let index = self.selectionIndex {
                self.visibleLimit = max(300, index + 1)
            }
        }
    }

    private static func preferredChange(in changes: [SVNChangedPath], path: String) -> SVNChangedPath? {
        if let exact = changes.first(where: { $0.path == path }) { return exact }
        // A unique recorded copy source can identify the moved path. Multiple
        // copies are ambiguous, so leave the selection for the user to choose.
        let copies = changes.filter { $0.copyFromPath == path }
        return copies.count == 1 ? copies[0] : nil
    }

    private nonisolated static func matching(_ changes: [SVNChangedPath], query: String) throws -> [SVNChangedPath] {
        try Task.checkCancellation()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return changes }
        var matches: [SVNChangedPath] = []
        for (index, change) in changes.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if change.path.localizedStandardContains(query) || change.copyFromPath?.localizedStandardContains(query) == true {
                matches.append(change)
            }
        }
        return matches
    }

    private func remember(_ text: String, for path: String) {
        if let previous = cache.removeValue(forKey: path) { cacheBytes -= previous.utf8.count }
        cacheOrder.removeAll { $0 == path }
        let bytes = text.utf8.count
        guard bytes <= 8_000_000 else { return }
        while !cacheOrder.isEmpty && (cacheBytes + bytes > 8_000_000 || cache.count >= 12) {
            if let removed = cache.removeValue(forKey: cacheOrder.removeFirst()) { cacheBytes -= removed.utf8.count }
        }
        cache[path] = text
        cacheOrder.append(path)
        cacheBytes += bytes
    }
}
