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
    @Published var pathQuery = "" { didSet { filterPaths() } }

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

    convenience init(store: SvnDockStore) {
        self.init(detailsLoader: { try await store.revisionDetails(for: $0) }, diffLoader: {
            try await store.revisionDiff(for: $0, change: $1, repositoryRoot: $2)
        })
    }

    var selectedChange: SVNChangedPath? {
        filteredChanges.first { $0.path == selectedPath }
    }
    var displayedChanges: [SVNChangedPath] { Array(filteredChanges.prefix(visibleLimit)) }
    var selectionIndex: Int? { filteredChanges.firstIndex { $0.path == selectedPath } }

    func load(_ request: SvnDockRevisionRequest) async {
        let previousPath = selectedPath
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
            filterTask?.cancel()
            filterGeneration = UUID()
            isFiltering = false
            isLoading = false
            filteredChanges = Self.matching(loaded.changes, query: pathQuery)
            visibleLimit = 300
            let preferred = filteredChanges.first { $0.path == (previousPath ?? request.preferredPath) }
                ?? filteredChanges.first { $0.kind != .directory } ?? filteredChanges.first
            select(preferred?.path)
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
        if !force, let cached = cache[change.path] { diffText = cached; return }
        isLoadingDiff = true
        let loader = diffLoader
        diffTask = Task { [weak self] in
            do {
                let text = try await loader(request, change, details.repositoryRootURL)
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
        isLoading = false
        isLoadingDiff = false
        isFiltering = false
    }

    private func filterPaths() {
        filterTask?.cancel()
        let generation = UUID()
        filterGeneration = generation
        let query = pathQuery
        let changes = details?.changes ?? []
        isFiltering = true
        filterTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let matches = await Task.detached(priority: .userInitiated) {
                Self.matching(changes, query: query)
            }.value
            guard let self, !Task.isCancelled, self.filterGeneration == generation else { return }
            self.filteredChanges = matches
            self.visibleLimit = 300
            self.isFiltering = false
            if !matches.contains(where: { $0.path == self.selectedPath }) {
                self.select(matches.first?.path)
            } else if let index = self.selectionIndex {
                self.visibleLimit = max(300, index + 1)
            }
        }
    }

    private nonisolated static func matching(_ changes: [SVNChangedPath], query: String) -> [SVNChangedPath] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return changes }
        return changes.filter {
            $0.path.localizedStandardContains(query) || $0.copyFromPath?.localizedStandardContains(query) == true
        }
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
