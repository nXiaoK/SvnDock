import Combine
import Foundation
import ServiceManagement

enum SvnDockLoginItemStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

@MainActor
protocol SvnDockLoginItemManaging {
    var status: SvnDockLoginItemStatus { get }
    func register() throws
    func unregister() async throws
    func openSettings()
}

@MainActor
private struct SystemLoginItemManager: SvnDockLoginItemManaging {
    var status: SvnDockLoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() async throws {
        try await SMAppService.mainApp.unregister()
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
final class SvnDockPreferences: ObservableObject {
    @Published private(set) var showsMenuBarIcon: Bool
    @Published private(set) var loginItemStatus: SvnDockLoginItemStatus
    @Published private(set) var loginItemError: String?
    @Published private(set) var isUpdatingLoginItem = false

    private static let menuBarIconKey = "SvnDock.showsMenuBarIcon"
    private let defaults: UserDefaults
    private let loginItemManager: any SvnDockLoginItemManaging

    init(
        defaults: UserDefaults = .standard,
        loginItemManager: (any SvnDockLoginItemManaging)? = nil
    ) {
        let manager = loginItemManager ?? SystemLoginItemManager()
        self.defaults = defaults
        self.loginItemManager = manager
        self.showsMenuBarIcon = defaults.bool(forKey: Self.menuBarIconKey)
        self.loginItemStatus = manager.status
    }

    /// An item awaiting approval is already registered and can be turned off.
    var launchAtLogin: Bool {
        loginItemStatus == .enabled || loginItemStatus == .requiresApproval
    }

    func setShowsMenuBarIcon(_ visible: Bool) {
        // MenuBarExtra can write its current visibility back during scene
        // updates. Avoid publishing it again and invalidating the same scene.
        guard visible != showsMenuBarIcon else { return }
        showsMenuBarIcon = visible
        defaults.set(visible, forKey: Self.menuBarIconKey)
    }

    func refreshLoginItemStatus() {
        let status = loginItemManager.status
        guard status != loginItemStatus else { return }
        loginItemStatus = status
    }

    func setLaunchAtLogin(_ enabled: Bool) async {
        guard !isUpdatingLoginItem else { return }
        loginItemError = nil
        refreshLoginItemStatus()
        guard enabled != launchAtLogin else { return }

        isUpdatingLoginItem = true
        defer {
            // Query macOS after success or failure; a registration request may
            // still require approval or partially change state before failing.
            refreshLoginItemStatus()
            isUpdatingLoginItem = false
        }
        do {
            if enabled {
                try loginItemManager.register()
            } else {
                try await loginItemManager.unregister()
            }
        } catch {
            loginItemError = error.localizedDescription
        }
    }

    func openLoginItemsSettings() {
        loginItemManager.openSettings()
    }

    func dismissLoginItemError() {
        loginItemError = nil
    }
}
