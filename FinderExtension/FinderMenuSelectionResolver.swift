import Foundation

/// Describes which Finder surface requested a menu without coupling the
/// selection rules to FinderSync framework types.
enum FinderMenuContext {
    case items
    case container
    case sidebar
    case toolbar
    case unsupported
}

/// Resolves the URLs that a Finder menu is allowed to act on.
///
/// Finder can retain selected rows while the user opens a menu for a window
/// background or sidebar item. Each surface therefore has an explicit source
/// of truth instead of sharing one selection fallback rule.
enum FinderMenuSelectionResolver {
    static func urls(
        for context: FinderMenuContext,
        selectedURLs: [URL],
        targetedURL: URL?
    ) -> [URL] {
        let candidates: [URL]
        switch context {
        case .items:
            candidates = selectedURLs
        case .container, .sidebar:
            candidates = targetedURL.map { [$0] } ?? []
        case .toolbar:
            candidates = selectedURLs.isEmpty
                ? targetedURL.map { [$0] } ?? []
                : selectedURLs
        case .unsupported:
            candidates = []
        }

        var seenPaths = Set<String>()
        return candidates.compactMap { url in
            guard url.isFileURL else { return nil }
            let canonicalURL = url.standardizedFileURL
            guard seenPaths.insert(canonicalURL.path).inserted else { return nil }
            return canonicalURL
        }
    }
}
