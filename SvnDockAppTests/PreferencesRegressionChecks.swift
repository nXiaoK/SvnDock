import Combine
import Foundation
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

@MainActor
enum PreferencesRegressionChecks {
    static func run() async throws {
        let suiteName = "svndock-preferences-\(UUID())"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw PreferencesCheckFailure(message: "could not create isolated preferences")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = TestLoginItemManager()
        let preferences = SvnDockPreferences(defaults: defaults, loginItemManager: manager)
        try check(!preferences.showsMenuBarIcon, "menu bar icon is opt-in")
        try check(!preferences.launchAtLogin, "new preferences reflect unregistered OS state")
        try check(manager.registrationCount == 0 && manager.unregistrationCount == 0,
                  "loading preferences never modifies login registration")

        var updates = 0
        let subscription = preferences.objectWillChange.sink { updates += 1 }
        preferences.setShowsMenuBarIcon(false)
        preferences.refreshLoginItemStatus()
        try check(updates == 0, "unchanged visibility and system status do not invalidate scenes")

        preferences.setShowsMenuBarIcon(true)
        try check(updates == 1, "changing menu visibility publishes one update")
        preferences.setShowsMenuBarIcon(true)
        preferences.refreshLoginItemStatus()
        try check(updates == 1, "menu visibility writeback does not trigger a scene update loop")
        let restored = SvnDockPreferences(defaults: defaults, loginItemManager: manager)
        try check(restored.showsMenuBarIcon, "menu bar choice survives relaunch")
        restored.setShowsMenuBarIcon(false)
        let hidden = SvnDockPreferences(defaults: defaults, loginItemManager: manager)
        try check(!hidden.showsMenuBarIcon, "disabling menu bar icon survives relaunch")

        manager.status = .requiresApproval
        preferences.refreshLoginItemStatus()
        try check(updates == 2, "changing system status publishes one update")
        preferences.refreshLoginItemStatus()
        try check(updates == 2, "refreshing unchanged system status publishes no update")
        manager.status = .notRegistered
        preferences.refreshLoginItemStatus()
        subscription.cancel()

        await preferences.setLaunchAtLogin(true)
        try check(preferences.launchAtLogin && preferences.loginItemStatus == .enabled,
                  "successful registration uses the resulting OS status")
        try check(!preferences.isUpdatingLoginItem && preferences.loginItemError == nil,
                  "successful registration clears progress and errors")
        await preferences.setLaunchAtLogin(true)
        try check(manager.registrationCount == 1, "already enabled registration is not repeated")
        await preferences.setLaunchAtLogin(false)
        try check(!preferences.launchAtLogin && manager.unregistrationCount == 1,
                  "disabling unregisters the login item")

        manager.registrationResult = .requiresApproval
        await preferences.setLaunchAtLogin(true)
        try check(preferences.loginItemStatus == .requiresApproval && preferences.launchAtLogin,
                  "pending approval remains registered without claiming enabled status")
        preferences.openLoginItemsSettings()
        try check(manager.settingsCount == 1, "approval settings are opened only on request")
        await preferences.setLaunchAtLogin(false)
        try check(!preferences.launchAtLogin && manager.unregistrationCount == 2,
                  "a registration awaiting approval can be disabled")

        manager.registrationError = TestLoginItemFailure.denied
        await preferences.setLaunchAtLogin(true)
        try check(!preferences.launchAtLogin && preferences.loginItemError == "registration denied",
                  "failed registration preserves the OS state and exposes the error")
        try check(!preferences.isUpdatingLoginItem, "failed registration ends progress")
        preferences.dismissLoginItemError()
        try check(preferences.loginItemError == nil, "dismissal clears the displayed error")

        manager.status = .enabled
        preferences.refreshLoginItemStatus()
        try check(preferences.launchAtLogin, "refresh detects externally enabled login item")
        manager.unregistrationError = TestLoginItemFailure.busy
        await preferences.setLaunchAtLogin(false)
        try check(preferences.launchAtLogin && preferences.loginItemError == "unregistration failed",
                  "failed unregistration preserves the OS state and exposes the error")
        try check(!preferences.isUpdatingLoginItem, "failed unregistration ends progress")

        manager.status = .notFound
        preferences.refreshLoginItemStatus()
        try check(preferences.loginItemStatus == .notFound && !preferences.launchAtLogin,
                  "refresh detects unavailable login registration")
        let fresh = SvnDockPreferences(defaults: defaults, loginItemManager: manager)
        try check(fresh.loginItemStatus == .notFound && !fresh.launchAtLogin,
                  "relaunch reads OS status rather than a persisted launch-at-login flag")

        // An external change between refresh and a toggle must be reconciled
        // before deciding whether an OS operation is necessary.
        manager.status = .enabled
        let callsBeforeExternalChange = manager.registrationCount
        await preferences.setLaunchAtLogin(true)
        try check(preferences.launchAtLogin && manager.registrationCount == callsBeforeExternalChange,
                  "toggle refreshes external state before registering")
        try check(preferences.loginItemError == nil, "retry clears a stale operation error")

        let unavailableManager = TestLoginItemManager()
        unavailableManager.status = .notFound
        unavailableManager.registrationError = .denied
        let unavailable = SvnDockPreferences(defaults: defaults, loginItemManager: unavailableManager)
        var publishedStatuses: [SvnDockLoginItemStatus] = []
        let statusSubscription = unavailable.$loginItemStatus.sink { publishedStatuses.append($0) }

        await unavailable.setLaunchAtLogin(true)
        try check(unavailableManager.registrationCount == 1,
                  "unavailable initial status still allows a registration attempt")
        try check(unavailable.loginItemStatus == .notFound && !unavailable.launchAtLogin
                  && unavailable.loginItemError == "registration denied" && !unavailable.isUpdatingLoginItem,
                  "registration failure from unavailable status exposes the actual error")

        unavailableManager.registrationError = nil
        await unavailable.setLaunchAtLogin(true)
        try check(unavailableManager.registrationCount == 2 && unavailable.launchAtLogin
                  && unavailable.loginItemError == nil && !unavailable.isUpdatingLoginItem,
                  "registration can recover from an unavailable initial status")
        try check(publishedStatuses == [.notFound, .enabled],
                  "successful registration publishes the resulting system status")
        statusSubscription.cancel()
    }

    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw PreferencesCheckFailure(message: message) }
    }
}

@MainActor
private final class TestLoginItemManager: SvnDockLoginItemManaging {
    var status: SvnDockLoginItemStatus = .notRegistered
    var registrationResult: SvnDockLoginItemStatus = .enabled
    var registrationError: TestLoginItemFailure?
    var unregistrationError: TestLoginItemFailure?
    private(set) var registrationCount = 0
    private(set) var unregistrationCount = 0
    private(set) var settingsCount = 0

    func register() throws {
        registrationCount += 1
        if let registrationError { throw registrationError }
        status = registrationResult
    }

    func unregister() async throws {
        unregistrationCount += 1
        if let unregistrationError { throw unregistrationError }
        status = .notRegistered
    }

    func openSettings() {
        settingsCount += 1
    }
}

private enum TestLoginItemFailure: LocalizedError {
    case denied
    case busy

    var errorDescription: String? {
        switch self {
        case .denied: "registration denied"
        case .busy: "unregistration failed"
        }
    }
}

private struct PreferencesCheckFailure: Error {
    let message: String
}
