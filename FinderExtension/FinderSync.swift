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

    private let controller = FIFinderSyncController.default()
    private let container: SharedContainer
    private let state: SharedStateStore
    private let dispatcher: FinderCommandDispatcher
    /// Finder recreates extension menu items across its XPC boundary and may
    /// drop `representedObject`. A bounded token map keeps each menu tied to
    /// its own immutable selection instead of relying on one global snapshot.
    private var retainedMenuPayloads: [Int: RetainedCommandMenuPayload] = [:]

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
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    override func beginObservingDirectory(at url: URL) {
        // SVN status is produced by the main app/agent and arrives as a badge
        // snapshot. Starting observation intentionally performs no repository I/O.
        reloadSharedState()
    }

    override func endObservingDirectory(at url: URL) {}

    override func requestBadgeIdentifier(for url: URL) {
        let identifier = state.badge(for: url)?.finderBadgeIdentifier
            ?? FinderBadgeIdentifier.none
        controller.setBadgeIdentifier(identifier, for: url)
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
        let isRoot = selection.urls.count == 1 && selection.urls[0].path == root.path
        let isSingleItem = selection.urls.count == 1
        let singleStatus = isSingleItem ? state.badge(for: selection.urls[0]) : nil
        let hasConflict = statuses.contains(.conflicted)
        let hasUnversioned = statuses.contains(.unversioned)
        let hasVersionedChange = statuses.contains(where: \.isLocalChange)

        let contextStatus: String
        if hasConflict {
            contextStatus = "有冲突"
        } else if hasVersionedChange {
            contextStatus = "有本地修改"
        } else if hasUnversioned {
            contextStatus = "未纳管"
        } else {
            contextStatus = "SVN 工作副本"
        }
        let contextTitle = root.displayName ?? root.canonicalURL?.lastPathComponent ?? "SvnDock"
        let contextItem = NSMenuItem(
            title: "\(contextTitle) · \(contextStatus)",
            action: nil,
            keyEquivalent: ""
        )
        contextItem.isEnabled = false
        submenu.addItem(contextItem)
        submenu.addItem(.separator())

        submenu.addItem(makeCommandItem("刷新状态", action: #selector(refresh(_:)), payload: payload))
        submenu.addItem(makeCommandItem("更新", action: #selector(update(_:)), payload: payload))
        submenu.addItem(makeCommandItem("提交…", action: #selector(commit(_:)), payload: payload))
        submenu.addItem(.separator())

        if !isRoot {
            submenu.addItem(makeCommandItem("添加到 SVN", action: #selector(add(_:)), payload: payload))
            if isSingleItem {
                submenu.addItem(makeCommandItem("查看差异", action: #selector(diff(_:)), payload: payload))
            }
            submenu.addItem(makeCommandItem("还原…", action: #selector(revert(_:)), payload: payload))
        }

        // Badge snapshots are only a menu-visibility hint. The main app must
        // reload authoritative SVN state before executing any of these actions.
        // A clean versioned item has no badge, so history remains available
        // when the cached status is absent; an explicitly unversioned item does
        // not have repository history.
        if isSingleItem, isRoot || (singleStatus != .unversioned && singleStatus != .ignored) {
            submenu.addItem(makeCommandItem("查看历史…", action: #selector(log(_:)), payload: payload))
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
        let roots = state.reload()
        let rootURLs = roots.compactMap(\.canonicalURL)
        // Finder monitors every registered root recursively. Registering each
        // descendant would be both redundant and prohibitively expensive for
        // large working copies.
        if Thread.isMainThread {
            controller.directoryURLs = Set(rootURLs)
        } else {
            DispatchQueue.main.async {
                FIFinderSyncController.default().directoryURLs = Set(rootURLs)
            }
        }
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
        registerBadge(
            identifier: FinderBadgeIdentifier.conflicted,
            symbol: "exclamationmark.octagon.fill",
            label: "SVN 冲突"
        )
        registerBadge(
            identifier: FinderBadgeIdentifier.modified,
            symbol: "pencil.circle.fill",
            label: "SVN 已修改"
        )
        registerBadge(
            identifier: FinderBadgeIdentifier.added,
            symbol: "plus.circle.fill",
            label: "SVN 已添加"
        )
        registerBadge(
            identifier: FinderBadgeIdentifier.deleted,
            symbol: "minus.circle.fill",
            label: "SVN 已删除"
        )
        registerBadge(
            identifier: FinderBadgeIdentifier.unversioned,
            symbol: "questionmark.circle.fill",
            label: "SVN 未纳管"
        )
        registerBadge(
            identifier: FinderBadgeIdentifier.missing,
            symbol: "xmark.circle.fill",
            label: "SVN 文件缺失"
        )
    }

    private func registerBadge(identifier: String, symbol: String, label: String) {
        guard let image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: label
        ) else { return }
        image.isTemplate = false
        controller.setBadgeImage(image, label: label, forBadgeIdentifier: identifier)
    }
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
