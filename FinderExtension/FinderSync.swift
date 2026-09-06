import AppKit
import FinderSync
import OSLog

final class FinderSync: FIFinderSync {
    private static let logger = Logger(
        subsystem: "com.svndock.app.finder",
        category: "finder-sync"
    )

    private static let sharedStateNotification = Notification.Name(
        "com.svndock.shared-state-changed"
    )

    private static let commandItemIdentifierPrefix = "com.svndock.finder.command."
    private static let retainedMenuPayloadLimit = 16
    private static let retainedMenuPayloadLifetime: TimeInterval = 10 * 60

    private var controller: FIFinderSyncController { FIFinderSyncController.default() }
    private let container: SharedContainer
    private let state: SharedStateStore
    private let dispatcher: FinderCommandDispatcher
    /// Finder recreates extension menu items across its XPC boundary and may
    /// drop `representedObject`. A bounded token map keeps each menu tied to
    /// its own immutable selection instead of relying on one global snapshot.
    private var retainedMenuPayloads: [Int: RetainedCommandMenuPayload] = [:]
    // These fields are confined to the main thread, including polling and
    // callbacks forwarded from Finder's delivery thread.
    private var badgeTracker = FinderBadgeTracker()
    private let badgeRequestInstanceID = UUID()
    private var badgePollTimer: Timer?
    private var badgePollTarget: FinderBadgePollTarget?
    private var lastBadgeRequestAt = Date.distantPast
    private var lastBadgeRequestError: String?
    private var configuredDirectoryURLs: Set<URL>?
    private var hasReceivedBadgeRequest = false

    override init() {
        let container = SharedContainer()
        let state = SharedStateStore(container: container)
        self.container = container
        self.state = state
        self.dispatcher = FinderCommandDispatcher(container: container, state: state)
        super.init()

        registerBadgeImages()
        reloadSharedState()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(sharedStateDidChange(_:)),
            name: Self.sharedStateNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        let target = FinderBadgePollTarget(owner: self)
        let timer = Timer(timeInterval: 5, target: target, selector: #selector(FinderBadgePollTarget.fire(_:)),
                          userInfo: nil, repeats: true)
        badgePollTarget = target
        badgePollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit {
        badgePollTimer?.invalidate()
        try? container.writeBadgeRequest(instanceID: badgeRequestInstanceID, directories: [])
        DistributedNotificationCenter.default().removeObserver(self)
    }

    override func beginObservingDirectory(at url: URL) {
        // SVN status is produced by the main app/agent and arrives as a badge
        // snapshot. Starting observation intentionally performs no repository I/O.
        performOnMain(#selector(observeDirectory(_:)), value: url)
    }

    override func endObservingDirectory(at url: URL) {
        performOnMain(#selector(stopObservingDirectory(_:)), value: url)
    }

    override func requestBadgeIdentifier(for url: URL) {
        Self.logger.debug("Received Finder badge request")
        performOnMain(#selector(applyBadgeRequest(_:)), value: url)
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        // This also picks up changes if a distributed notification was missed.
        reloadSharedState()

        let selection = currentSelection(for: menuKind)
        let menu = NSMenu(title: "SvnDock")
        guard !selection.urls.isEmpty, let root = selection.root else {
            menu.addItem(makeItem(title: "在 SvnDock 中打开", action: #selector(openMainApp(_:))))
            return menu
        }

        let parent = NSMenuItem(title: "SvnDock", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "SvnDock")
        parent.submenu = submenu
        menu.addItem(parent)

        let payload = retainCommandMenuPayload(urls: selection.urls, root: root)
        let statuses = selection.urls.compactMap(state.badge(for:))
        let isFresh = selection.urls.allSatisfy { state.isFresh(for: $0) }
        let isRoot = selection.urls.count == 1 && selection.urls[0].path == root.path
        let isSingleItem = selection.urls.count == 1
        // Ancestor badges describe a subtree, never an exact node's ability
        // to be added, ignored or marked resolved. Stale/legacy data is unknown.
        let singleStatus = isSingleItem && isFresh ? state.directBadge(for: selection.urls[0]) : nil
        let hasConflict = statuses.contains(.conflicted)
        let hasUnversioned = statuses.contains(.unversioned)
        let hasVersionedChange = statuses.contains(where: \.isLocalChange)

        let contextStatus: String
        let contextBadgeIdentifier: String
        if !isFresh {
            contextStatus = "状态待刷新"
            contextBadgeIdentifier = FinderBadgeIdentifier.stale
        } else if hasConflict {
            contextStatus = "有冲突"
            contextBadgeIdentifier = FinderBadgeIdentifier.conflicted
        } else if hasVersionedChange {
            contextStatus = "有本地修改"
            contextBadgeIdentifier = FinderBadgeIdentifier.modified
        } else if hasUnversioned {
            contextStatus = "未纳管"
            contextBadgeIdentifier = FinderBadgeIdentifier.unversioned
        } else if statuses.contains(.ignored) {
            contextStatus = "已忽略"
            contextBadgeIdentifier = FinderBadgeIdentifier.ignored
        } else if statuses.count == selection.urls.count && statuses.allSatisfy({ $0 == .clean }) {
            contextStatus = "正常"
            contextBadgeIdentifier = FinderBadgeIdentifier.clean
        } else {
            contextStatus = "状态待确认"
            contextBadgeIdentifier = FinderBadgeIdentifier.unknown
        }
        let contextTitle = root.displayName ?? root.canonicalURL?.lastPathComponent ?? "SvnDock"
        let contextItem = NSMenuItem(
            title: "\(contextTitle) · \(contextStatus)",
            action: nil,
            keyEquivalent: ""
        )
        contextItem.isEnabled = false
        if let spec = FinderBadgeSymbolSpec.all.first(where: { $0.identifier == contextBadgeIdentifier }) {
            contextItem.image = badgeImage(for: spec)
        }
        submenu.addItem(contextItem)
        submenu.addItem(.separator())

        let commitTitle = selection.urls.count > 1 ? "提交所选 \(selection.urls.count) 项…"
            : isRoot ? "提交工作副本…" : "提交所选项目…"
        submenu.addItem(makeCommandItem(commitTitle, action: #selector(commit(_:)), payload: payload))

        // Badge snapshots are only a menu-visibility hint. The main app must
        // reload authoritative SVN state before executing any of these actions.
        // Unknown cached status keeps history/diff available for validation in
        // the app; an explicitly unversioned or ignored item has no history.
        if isSingleItem, isRoot || (singleStatus != .unversioned && singleStatus != .ignored) {
            let isDirectory = isRoot
                || (try? selection.urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            submenu.addItem(makeCommandItem("查看历史…", action: #selector(log(_:)), payload: payload))
            submenu.addItem(makeCommandItem(isDirectory ? "查看目录属性差异" : "查看差异",
                                           action: #selector(diff(_:)), payload: payload))
        }
        submenu.addItem(.separator())
        submenu.addItem(makeCommandItem("刷新状态", action: #selector(refresh(_:)), payload: payload))
        submenu.addItem(makeCommandItem("更新整个工作副本", action: #selector(update(_:)), payload: payload))
        if !isRoot {
            submenu.addItem(makeCommandItem("添加到 SVN", action: #selector(add(_:)), payload: payload))
            submenu.addItem(makeCommandItem("还原…", action: #selector(revert(_:)), payload: payload))
        }

        // Keep the first conflict workflow deliberately narrow: one exact
        // conflicted node, never the aggregate badge on a working-copy root.
        if isSingleItem, !isRoot, singleStatus == .conflicted {
            submenu.addItem(makeCommandItem(
                "标记冲突已解决…",
                action: #selector(resolve(_:)),
                payload: payload
            ))
        }

        // Ignore patterns are derived by the main app from the selected path;
        // Finder never transports an arbitrary user-provided pattern.
        if isSingleItem, !isRoot, singleStatus == .unversioned {
            let ignoreItem = NSMenuItem(title: "忽略", action: nil, keyEquivalent: "")
            let ignoreMenu = NSMenu(title: "忽略")
            ignoreMenu.addItem(makeCommandItem(
                "按名称忽略",
                action: #selector(ignoreName(_:)),
                payload: payload
            ))

            if isRegularFileWithExtension(selection.urls[0]) {
                ignoreMenu.addItem(makeCommandItem(
                    "按扩展名忽略",
                    action: #selector(ignoreExtension(_:)),
                    payload: payload
                ))
            }
            ignoreItem.submenu = ignoreMenu
            submenu.addItem(ignoreItem)
        }

        if !submenu.items.isEmpty, submenu.items.last?.isSeparatorItem == false {
            submenu.addItem(.separator())
        }
        submenu.addItem(makeCommandItem("复制仓库 URL", action: #selector(copyRepositoryURL(_:)), payload: payload))
        if isRoot {
            submenu.addItem(makeCommandItem("清理工作副本…", action: #selector(cleanup(_:)), payload: payload))
        }
        submenu.addItem(.separator())
        submenu.addItem(makeCommandItem("在 SvnDock 中打开", action: #selector(openMainApp(_:)), payload: payload))
        return menu
    }

    override var toolbarItemName: String { "SvnDock" }

    override var toolbarItemToolTip: String { "在 SvnDock 中打开当前工作副本" }

    override var toolbarItemImage: NSImage {
        NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "SvnDock")
            ?? NSImage(size: NSSize(width: 16, height: 16))
    }

    @objc private func sharedStateDidChange(_ notification: Notification) {
        reloadSharedState()
    }

    @objc private func refresh(_ sender: NSMenuItem) { dispatch(.refresh, sender: sender) }
    @objc private func update(_ sender: NSMenuItem) { dispatch(.update, sender: sender) }
    @objc private func commit(_ sender: NSMenuItem) { dispatch(.commit, sender: sender) }
    @objc private func diff(_ sender: NSMenuItem) { dispatch(.diff, sender: sender) }
    @objc private func add(_ sender: NSMenuItem) { dispatch(.add, sender: sender) }
    @objc private func revert(_ sender: NSMenuItem) { dispatch(.revert, sender: sender) }
    @objc private func cleanup(_ sender: NSMenuItem) { dispatch(.cleanup, sender: sender) }
    @objc private func log(_ sender: NSMenuItem) { dispatch(.log, sender: sender) }
    @objc private func resolve(_ sender: NSMenuItem) { dispatch(.resolve, sender: sender) }
    @objc private func copyRepositoryURL(_ sender: NSMenuItem) { dispatch(.copyRepositoryURL, sender: sender) }
    @objc private func ignoreName(_ sender: NSMenuItem) { dispatch(.ignoreName, sender: sender) }
    @objc private func ignoreExtension(_ sender: NSMenuItem) { dispatch(.ignoreExtension, sender: sender) }

    @objc private func openMainApp(_ sender: NSMenuItem) {
        guard let payload = commandPayload(from: sender) else {
            // A menu item without its immutable payload may come from a
            // rootless or unsupported Finder context. Opening the app is safe;
            // reconstructing a command from Finder's current state is not.
            dispatcher.openMainApp()
            return
        }
        _ = dispatcher.dispatch(kind: .openApp, urls: payload.urls, expectedRoot: payload.root)
    }

    private func dispatch(_ kind: FinderCommandKind, sender: NSMenuItem) {
        guard let payload = commandPayload(from: sender) else {
            Self.logger.error("Finder command has no recoverable selection payload")
            NSSound.beep()
            return
        }
        _ = dispatcher.dispatch(kind: kind, urls: payload.urls, expectedRoot: payload.root)
    }

    private func commandPayload(from sender: NSMenuItem) -> CommandMenuPayload? {
        if let payload = sender.representedObject as? CommandMenuPayload {
            let hasStandardToken = sender.tag > 0
                || sender.identifier?.rawValue.hasPrefix(Self.commandItemIdentifierPrefix) == true
            if hasStandardToken, commandMenuToken(from: sender) != payload.menuToken {
                Self.logger.error("Finder representedObject disagrees with its command token")
                return nil
            }
            retainedMenuPayloads.removeValue(forKey: payload.menuToken)
            return payload
        }

        pruneRetainedMenuPayloads()
        guard let token = commandMenuToken(from: sender),
              let retained = retainedMenuPayloads.removeValue(forKey: token) else {
            let identifier = sender.identifier?.rawValue ?? "<none>"
            Self.logger.error(
                "Finder omitted an exact command payload; tag=\(sender.tag, privacy: .public) identifier=\(identifier, privacy: .public)"
            )
            return nil
        }
        Self.logger.notice(
            "Finder omitted representedObject; recovered exact menu token \(token, privacy: .public)"
        )
        return retained.payload
    }

    private func retainCommandMenuPayload(
        urls: [URL],
        root: RegisteredRoot
    ) -> CommandMenuPayload {
        pruneRetainedMenuPayloads()
        while retainedMenuPayloads.count >= Self.retainedMenuPayloadLimit,
              let oldest = retainedMenuPayloads.min(by: {
                  $0.value.createdAt < $1.value.createdAt
              })?.key {
            retainedMenuPayloads.removeValue(forKey: oldest)
        }

        var token: Int
        repeat {
            token = Int.random(in: 1...Int(Int32.max))
        } while retainedMenuPayloads[token] != nil

        let payload = CommandMenuPayload(menuToken: token, urls: urls, root: root)
        retainedMenuPayloads[token] = RetainedCommandMenuPayload(
            payload: payload,
            createdAt: Date()
        )
        return payload
    }

    private func commandMenuToken(from sender: NSMenuItem) -> Int? {
        let tagToken = sender.tag > 0 ? sender.tag : nil
        let identifierToken = sender.identifier?.rawValue
            .stripPrefix(Self.commandItemIdentifierPrefix)
            .flatMap { suffix -> Int? in
                guard let tokenText = suffix.split(separator: ".", maxSplits: 1).first else {
                    return nil
                }
                return Int(tokenText)
            }

        if let tagToken, let identifierToken, tagToken != identifierToken {
            Self.logger.error(
                "Finder command token fields disagree: tag=\(tagToken, privacy: .public) identifier=\(identifierToken, privacy: .public)"
            )
            return nil
        }
        return identifierToken ?? tagToken
    }

    private func pruneRetainedMenuPayloads() {
        let cutoff = Date().addingTimeInterval(-Self.retainedMenuPayloadLifetime)
        let expiredTokens = retainedMenuPayloads.compactMap { token, retained in
            retained.createdAt < cutoff ? token : nil
        }
        for token in expiredTokens {
            retainedMenuPayloads.removeValue(forKey: token)
        }
    }

    private func reloadSharedState() {
        state.reload()
        performOnMain(#selector(applySharedState), value: nil)
    }

    @objc fileprivate func pollSharedState() {
        reloadSharedState()
    }

    private func performOnMain(_ selector: Selector, value: URL?) {
        // NSObject forwarding avoids sharing mutable UI bookkeeping across
        // dispatch closures; wait when Finder expects an initial badge.
        if Thread.isMainThread {
            if let value { _ = perform(selector, with: value) }
            else { _ = perform(selector) }
        } else {
            performSelector(onMainThread: selector, with: value, waitUntilDone: true)
        }
    }

    @objc private func observeDirectory(_ url: URL) {
        state.reload()
        badgeTracker.observe(url, roots: state.registeredRoots())
        Self.logger.notice("Finder began observing a directory; registered roots: \(self.state.registeredRoots().count)")
        applySharedState()
    }

    @objc private func stopObservingDirectory(_ url: URL) {
        badgeTracker.stopObserving(url)
        publishBadgeRequests(force: true)
    }

    @objc private func applyBadgeRequest(_ url: URL) {
        let identifier = state.badgeIdentifier(for: url)
        badgeTracker.request(url, identifier: identifier, roots: state.registeredRoots())
        Self.logger.debug("Applying Finder badge: \(identifier, privacy: .public)")
        controller.setBadgeIdentifier(identifier, for: url)
        if !hasReceivedBadgeRequest {
            hasReceivedBadgeRequest = true
            Self.logger.notice("Delivered first Finder badge: \(identifier, privacy: .public)")
        }
        publishBadgeRequests(force: false)
    }

    @objc private func applySharedState() {
        // Read latest state on the main thread so queued callbacks cannot
        // restore old badges. Repaint only paths Finder already requested.
        for update in badgeTracker.badgeUpdates(using: { state.badgeIdentifier(for: $0) }) {
            controller.setBadgeIdentifier(update.identifier, for: update.url)
        }
        let roots = state.registeredRoots()
        badgeTracker.pruneUnregistered(roots: roots)
        // Finder monitors every registered root recursively. Registering each
        // descendant would be both redundant and prohibitively expensive for
        // large working copies.
        updateObservedDirectories(using: state)
        publishBadgeRequests(force: false)
    }

    private func publishBadgeRequests(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastBadgeRequestAt) >= 5 else { return }
        lastBadgeRequestAt = now
        do {
            try container.writeBadgeRequest(instanceID: badgeRequestInstanceID,
                directories: badgeTracker.directoryRequests(roots: state.registeredRoots()))
            lastBadgeRequestError = nil
        } catch {
            let detail = error.localizedDescription
            if lastBadgeRequestError != detail {
                Self.logger.error("Unable to publish Finder observation: \(detail, privacy: .public)")
                lastBadgeRequestError = detail
            }
        }
    }

    private func updateObservedDirectories(using state: SharedStateStore) {
        // Read the latest state after reaching the main queue so an older
        // callback cannot restore roots removed by a newer reload.
        let rootURLs = Set(state.registeredRoots().compactMap(\.canonicalURL))
        // Register unconditionally for this extension instance's first setup.
        // A controller getter reflecting an earlier connection is not proof
        // that Finder has registered the new instance's callbacks.
        guard configuredDirectoryURLs != rootURLs else { return }
        configuredDirectoryURLs = rootURLs
        controller.directoryURLs = rootURLs
        Self.logger.notice("Registered Finder observation roots: \(rootURLs.count)")
    }

    private func currentSelection(
        for menuKind: FIMenuKind
    ) -> (urls: [URL], root: RegisteredRoot?) {
        let context: FinderMenuContext
        switch menuKind {
        case .contextualMenuForItems:
            context = .items
        case .contextualMenuForContainer:
            context = .container
        case .contextualMenuForSidebar:
            context = .sidebar
        case .toolbarItemMenu:
            context = .toolbar
        @unknown default:
            Self.logger.error(
                "Rejected unsupported Finder menu kind \(menuKind.rawValue, privacy: .public)"
            )
            context = .unsupported
        }

        let urls = FinderMenuSelectionResolver.urls(
            for: context,
            selectedURLs: controller.selectedItemURLs() ?? [],
            targetedURL: controller.targetedURL()
        )
        guard let first = urls.first, let root = state.root(containing: first) else {
            return (urls, nil)
        }
        guard urls.dropFirst().allSatisfy({ state.root(containing: $0)?.id == root.id }) else {
            return (urls, nil)
        }
        return (urls, root)
    }

    private func makeItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        let symbol: String
        switch NSStringFromSelector(action) {
        case "commit:": symbol = "square.and.arrow.up"
        case "log:": symbol = "clock.arrow.circlepath"
        case "diff:": symbol = "doc.on.doc"
        case "refresh:": symbol = "arrow.clockwise"
        case "update:": symbol = "arrow.down.circle"
        case "add:": symbol = "plus.circle"
        case "revert:": symbol = "arrow.uturn.backward"
        case "resolve:": symbol = "checkmark.shield"
        case "copyRepositoryURL:": symbol = "link"
        case "cleanup:": symbol = "wrench.and.screwdriver"
        case "ignoreName:", "ignoreExtension:": symbol = "eye.slash"
        default: symbol = "arrow.up.forward.app"
        }
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    private func makeCommandItem(
        _ title: String,
        action: Selector,
        payload: CommandMenuPayload
    ) -> NSMenuItem {
        let item = makeItem(title: title, action: action)
        item.representedObject = payload
        item.tag = payload.menuToken
        item.identifier = NSUserInterfaceItemIdentifier(
            "\(Self.commandItemIdentifierPrefix)\(payload.menuToken).\(NSStringFromSelector(action))"
        )
        return item
    }

    private func isRegularFileWithExtension(_ url: URL) -> Bool {
        guard !url.pathExtension.isEmpty else { return false }
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func registerBadgeImages() {
        var count = 0
        for spec in FinderBadgeSymbolSpec.all {
            guard let image = badgeImage(for: spec) else {
                Self.logger.error("Unable to render Finder badge: \(spec.identifier, privacy: .public)")
                continue
            }
            controller.setBadgeImage(image, label: spec.label, forBadgeIdentifier: spec.identifier)
            count += 1
        }
        Self.logger.notice("Registered Finder bitmap badge images: \(count)")
    }

    private func badgeImage(for spec: FinderBadgeSymbolSpec) -> NSImage? {
        FinderBadgeImages.image(for: spec)
    }
}

private final class FinderBadgePollTarget: NSObject {
    weak var owner: FinderSync?
    init(owner: FinderSync) { self.owner = owner }
    @objc func fire(_ timer: Timer) { owner?.pollSharedState() }
}

/// Freezes the selection visible when Finder built the menu. Finder may omit
/// `representedObject` when it recreates an item, so standard menu-item token
/// fields recover this exact snapshot. The dispatcher revalidates it at click
/// time.
private final class CommandMenuPayload: NSObject {
    let menuToken: Int
    let urls: [URL]
    let root: RegisteredRoot

    init(menuToken: Int, urls: [URL], root: RegisteredRoot) {
        self.menuToken = menuToken
        self.urls = urls
        self.root = root
    }
}

private struct RetainedCommandMenuPayload {
    let payload: CommandMenuPayload
    let createdAt: Date
}

private extension String {
    func stripPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
