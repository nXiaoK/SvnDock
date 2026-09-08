import SwiftUI
import SvnDockCore

@main
struct SvnDockApplication: App {
    @StateObject private var store: SvnDockStore
    @StateObject private var preferences = SvnDockPreferences()
    @StateObject private var mainWindow = SvnDockMainWindowController()

    init() {
        _store = StateObject(wrappedValue: SvnDockAppEnvironment.makeStore())
    }

    var body: some Scene {
        WindowGroup(id: SvnDockMainWindowController.sceneID) {
            SvnDockRootView(store: store)
                .background {
                    SvnDockMainWindowReader(controller: mainWindow)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                // Route repeated Finder URLs to the existing main scene. A
                // WindowGroup otherwise creates a new window for each URL.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onOpenURL { url in
                    mainWindow.showExistingWindow()
                    Task { await store.handleFinderURL(url) }
                }
        }
        .defaultSize(width: 1_400, height: 860)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            SvnDockCommands(store: store)
        }

        WindowGroup("文件差异", for: SvnDockDiffRequest.self) { $request in
            if let request {
                SideBySideDiffWindow(store: store, request: request)
            } else {
                ContentUnavailableView(
                    "未选择文件",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("请在状态列表中双击一个文件。")
                )
            }
        }
        .defaultSize(width: 1_240, height: 760)

        WindowGroup("提交详情", for: SvnDockRevisionRequest.self) { $request in
            if let request {
                HistoryRevisionView(store: store, request: request, expanded: true)
                    .frame(minWidth: 960, minHeight: 560)
                    .navigationTitle("r\(request.revision) — 提交详情")
            }
        }
        .defaultSize(width: 1_240, height: 800)

        Settings {
            SvnDockSettingsView(preferences: preferences, finderStatusMessage: store.finderBadgeStatusMessage)
        }

        MenuBarExtra("SvnDock", systemImage: "externaldrive",
                     isInserted: Binding(
                        get: { preferences.showsMenuBarIcon },
                        set: { preferences.setShowsMenuBarIcon($0) }
                     )) {
            SvnDockMenuBarContent(store: store, mainWindow: mainWindow)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
private enum SvnDockAppEnvironment {
    private static let appGroupInfoKey = "SvnDockAppGroupIdentifier"
    private static let debugAppGroupIdentifier = "group.com.svndock.shared"

    static func makeStore() -> SvnDockStore {
        do {
            let appGroupIdentifier = try configuredAppGroupIdentifier()
            let directoryURL = try sharedDirectoryURL(
                appGroupIdentifier: appGroupIdentifier
            )
            let sharedStore = try FinderSharedStore(directoryURL: directoryURL)
            return SvnDockStore(
                service: try CoreSvnDockService(sharedStore: sharedStore),
                finderSharedStore: sharedStore
            )
        } catch {
            return SvnDockStore(service: UnavailableSvnDockService(error: error))
        }
    }

    private static func configuredAppGroupIdentifier(
        bundle: Bundle = .main
    ) throws -> String {
        let configured = (bundle.object(
            forInfoDictionaryKey: appGroupInfoKey
        ) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let configured,
           configured.hasPrefix("group."),
           configured.count > "group.".count,
           !configured.contains("$(") {
            return configured
        }

        #if DEBUG
        // SwiftPM executables and previews do not process the Xcode Info.plist.
        return debugAppGroupIdentifier
        #else
        throw SvnDockAppConfigurationError.invalidAppGroupIdentifier(
            key: appGroupInfoKey
        )
        #endif
    }

    private static func sharedDirectoryURL(
        appGroupIdentifier: String
    ) throws -> URL {
        #if SVNDOCK_PORTABLE_SIGNED_BUILD
        // Distributed ad-hoc builds resolve the recipient's account home at
        // runtime. No CI runner path is accepted from the sealed bundle.
        return try FinderSharedStoreLocation.portableSignedDirectory()
        #elseif SVNDOCK_LOCAL_SIGNED_BUILD
        // The reproducible Command Line Tools build is ad-hoc signed and has
        // no provisioned App Group. Its sealed Info.plist pins one private
        // Application Support directory shared with the local Finder build.
        return try FinderSharedStoreLocation.localSignedDirectory()
        #else
        do {
            return try FinderSharedStoreLocation.appGroupDirectory(
                groupIdentifier: appGroupIdentifier
            )
        } catch let locationError as FinderSharedStoreError {
            guard case .appGroupContainerUnavailable = locationError else {
                throw locationError
            }

            #if DEBUG
            #if !SWIFT_PACKAGE
            guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" else {
                // A real Xcode build must never silently use a private folder:
                // that would make the app appear healthy while Finder reads a
                // different App Group container.
                throw locationError
            }
            #endif

            // Debug SwiftPM runs and SwiftUI previews are not signed with an
            // App Group. Release builds never reach this fallback.
            guard let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw locationError
            }
            return applicationSupport
                .appendingPathComponent("SvnDock", isDirectory: true)
            #else
            // Release builds fail closed even if an untrusted environment
            // happens to contain XCODE_RUNNING_FOR_PREVIEWS.
            throw locationError
            #endif
        }
        #endif
    }
}

private enum SvnDockAppConfigurationError: LocalizedError, Sendable {
    case invalidAppGroupIdentifier(key: String)

    var errorDescription: String? {
        switch self {
        case .invalidAppGroupIdentifier(let key):
            return "发布版本缺少有效的 \(key)；请在 project.yml 中配置 SVNDOCK_APP_GROUP_IDENTIFIER。"
        }
    }
}

private struct UnavailableSvnDockService: SvnDockServicing {
    let message: String

    init(error: Error) {
        message = error.localizedDescription
    }

    func loadRegisteredWorkingCopies() async throws -> [SvnDockWorkingCopy] { throw unavailable }
    func registerWorkingCopy(at url: URL) async throws -> SvnDockWorkingCopy { throw unavailable }
    func unregisterWorkingCopy(id: UUID) async throws { throw unavailable }
    func status(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockStatusSnapshot { throw unavailable }
    func directoryChildren(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> [SvnDockStatusEntry] { throw unavailable }
    func diff(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> String { throw unavailable }
    func history(for workingCopy: SvnDockWorkingCopy, relativePaths: [String], limit: Int) async throws -> [SvnDockLogEntry] { throw unavailable }
    func revisionDetails(revision: Int, in workingCopy: SvnDockWorkingCopy) async throws -> SVNRevisionDetails { throw unavailable }
    func revisionDiff(revision: Int, change: SVNChangedPath, repositoryRoot: URL, in workingCopy: SvnDockWorkingCopy) async throws -> String { throw unavailable }
    func update(workingCopies: [SvnDockWorkingCopy]) async throws { throw unavailable }
    func commit(workingCopy: SvnDockWorkingCopy, relativePaths: [String], message: String) async throws { throw unavailable }
    func add(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func unscheduleAdd(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func cleanupMissingAdditions(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func scheduleMissingDeletion(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func revert(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func resolve(relativePaths: [String], using resolution: SvnDockConflictResolution, in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func addIgnoreRules(_ rules: [SvnDockIgnoreRule], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func cleanup(workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }

    private var unavailable: SvnDockServiceError {
        .unavailable(message)
    }
}

private struct SvnDockCommands: Commands {
    @ObservedObject var store: SvnDockStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("添加工作副本…") {
                store.requestDirectoryImport()
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(store.isInteractionBlocked)
        }

        CommandMenu("工作副本") {
            Button("刷新状态") {
                Task { await store.reloadSelectedWorkingCopy() }
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(store.selectedWorkingCopy == nil || store.isInteractionBlocked)

            Button("更新") {
                Task { await store.updateSelectedWorkingCopy() }
            }
            .keyboardShortcut("u", modifiers: [.command])
            .disabled(store.selectedWorkingCopy == nil || store.isInteractionBlocked)

            Button("提交…") {
                store.requestCommit()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!store.hasPendingChanges || store.isInteractionBlocked)

            Divider()

            Button("查看提交历史…") {
                Task { await store.showHistoryForSelection() }
            }
            .disabled(
                store.selectedWorkingCopy == nil
                    || store.selectedEntryIDs.count > 1
                    || store.isInteractionBlocked
            )

            Button("解决所选冲突…") {
                store.requestResolveConfirmation()
            }
            .disabled(
                store.primarySelectedEntry?.status != .conflicted
                    || store.isInteractionBlocked
            )

            Divider()

            Button("清理工作副本…") {
                Task { await store.cleanupSelectedWorkingCopy() }
            }
            .disabled(store.selectedWorkingCopy == nil || store.isInteractionBlocked)
        }
    }
}

private struct SvnDockMenuBarContent: View {
    @ObservedObject var store: SvnDockStore
    let mainWindow: SvnDockMainWindowController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SvnDockMenuBarView(store: store) {
            mainWindow.show(using: openWindow)
        }
    }
}
