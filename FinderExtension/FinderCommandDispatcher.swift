import AppKit
import Foundation
import OSLog

/// Queues Finder intent for the trusted main application. It never executes
/// `svn` and never includes file-system paths in the custom URL.
final class FinderCommandDispatcher {
    private static let logger = Logger(
        subsystem: "com.svndock.app.finder",
        category: "command-dispatch"
    )

    private let container: SharedContainer
    private let state: SharedStateStore
    private let mainAppURLScheme: String

    init(container: SharedContainer, state: SharedStateStore, bundle: Bundle = .main) {
        self.container = container
        self.state = state
        let configuredScheme = bundle.object(
            forInfoDictionaryKey: "SvnDockMainAppURLScheme"
        ) as? String
        self.mainAppURLScheme = configuredScheme.flatMap { $0.isEmpty ? nil : $0 } ?? "svndock"
    }

    func openMainApp() {
        wakeMainApp(requestID: nil, reason: "user-open")
    }

    @discardableResult
    func dispatch(kind: FinderCommandKind, urls: [URL], expectedRoot: RegisteredRoot?) -> Bool {
        // Reload immediately before a write so stale Finder menus cannot target
        // a root the user has since disabled in the main application.
        state.reload()
        let canonicalURLs = Self.uniqueCanonicalURLs(urls)
        guard !canonicalURLs.isEmpty,
              let currentRoot = validatedCommonRoot(for: canonicalURLs),
              expectedRoot == nil || currentRoot.id == expectedRoot?.id else {
            Self.logger.error("Rejected a Finder command because its selection no longer matches a registered root")
            wakeMainApp(requestID: nil, reason: "selection-invalid")
            NSSound.beep()
            return false
        }

        let request = FinderCommandRequest(
            kind: kind,
            paths: canonicalURLs.map(\.path),
            workingCopyRoot: currentRoot.path
        )
        do {
            try container.enqueue(request)
            wakeMainApp(requestID: request.id, reason: nil)
            return true
        } catch {
            Self.logger.error(
                "Unable to enqueue Finder command: \(String(describing: error), privacy: .public)"
            )
            // Safe degradation: ask the app to open, but do not leak selected
            // paths through a URL or attempt the SVN operation in Finder.
            wakeMainApp(requestID: nil, reason: "queue-unavailable")
            NSSound.beep()
            return false
        }
    }

    private func validatedCommonRoot(for urls: [URL]) -> RegisteredRoot? {
        guard let firstRoot = state.root(containing: urls[0]) else { return nil }
        guard urls.dropFirst().allSatisfy({ state.root(containing: $0)?.id == firstRoot.id }) else {
            return nil
        }
        return firstRoot
    }

    private func wakeMainApp(requestID: UUID?, reason: String?) {
        var components = URLComponents()
        components.scheme = mainAppURLScheme
        components.host = "finder-command"
        var items: [URLQueryItem] = []
        if let requestID {
            items.append(URLQueryItem(name: "request", value: requestID.uuidString.lowercased()))
        }
        if let reason {
            items.append(URLQueryItem(name: "reason", value: reason))
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    private static func uniqueCanonicalURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            guard url.isFileURL else { return nil }
            let canonical = url.standardizedFileURL
            guard seen.insert(canonical.path).inserted else { return nil }
            return canonical
        }
    }
}
