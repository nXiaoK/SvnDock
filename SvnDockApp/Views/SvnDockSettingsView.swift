import AppKit
import FinderSync
import SwiftUI

struct SvnDockSettingsView: View {
    @ObservedObject var preferences: SvnDockPreferences
    @State private var finderExtensionEnabled = false

    var body: some View {
        Form {
            Section("启动与菜单栏") {
                Toggle(isOn: Binding(
                    get: { preferences.launchAtLogin },
                    set: { enabled in
                        Task { await preferences.setLaunchAtLogin(enabled) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("登录时启动")
                        Text(loginItemDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(preferences.isUpdatingLoginItem)
                .accessibilityLabel("登录时启动")
                .accessibilityHint(loginItemDescription)
                .accessibilityIdentifier("launchAtLoginToggle")

                if preferences.isUpdatingLoginItem {
                    ProgressView("正在更新登录项…")
                        .controlSize(.small)
                }

                if let error = preferences.loginItemError {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("无法更改自启设置", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(error)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("收起提示") { preferences.dismissLoginItemError() }
                    }
                    .font(.caption)
                }

                Button(preferences.loginItemStatus == .requiresApproval
                       ? "前往系统设置允许自启…" : "管理系统登录项…") {
                    preferences.openLoginItemsSettings()
                }
                .controlSize(.small)

                Toggle(isOn: Binding(
                    get: { preferences.showsMenuBarIcon },
                    set: { preferences.setShowsMenuBarIcon($0) }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("显示菜单栏图标")
                        Text("快速查看状态、切换工作副本和执行常用操作。关闭主窗口后仍可使用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("显示菜单栏图标")
                .accessibilityIdentifier("showsMenuBarIconToggle")
            }

            Section("SVN 与 Finder") {
                LabeledContent("SVN 可执行文件") {
                    Text("自动检测 Homebrew 与系统路径")
                        .foregroundStyle(.secondary)
                }
                finderIntegrationSettings
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .tint(SvnDockTheme.accent)
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { refreshSystemStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshSystemStatus()
        }
    }

    private var finderIntegrationSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Finder 集成") {
                Label(finderExtensionEnabled ? "已启用" : "未启用",
                      systemImage: finderExtensionEnabled ? "checkmark.circle" : "circle.dashed")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("finderExtensionStatus")
            }

            Text(finderExtensionEnabled
                 ? "已允许 SvnDock Finder 在 Finder 中显示 SVN 状态和右键菜单。"
                 : "在系统扩展管理中开启“SvnDock Finder”，即可在 Finder 中查看 SVN 状态和使用右键菜单。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                FIFinderSyncController.showExtensionManagementInterface()
            } label: {
                Label("打开 Finder 扩展设置…", systemImage: "arrow.up.forward.app")
            }
            .controlSize(.small)
            .help("打开 macOS 的扩展管理界面，由你开启或关闭 SvnDock Finder。")
            .accessibilityIdentifier("openFinderExtensionSettings")

            DisclosureGroup("没有看到 SvnDock Finder？") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("请将 SvnDock.app 放入“应用程序”文件夹并启动，再重新打开扩展设置。不同 macOS 版本的入口可能不同，也可在系统设置中搜索“扩展”或“Finder”。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("打开系统登录项与扩展…") {
                        preferences.openLoginItemsSettings()
                    }
                    .controlSize(.small)
                    .help("打开系统登录项页面；较新 macOS 的扩展管理也位于此处。")
                    .accessibilityIdentifier("openFinderExtensionFallbackSettings")
                }
                .padding(.top, 6)
            }
            .font(.caption)
        }
    }

    private func refreshSystemStatus() {
        preferences.refreshLoginItemStatus()
        finderExtensionEnabled = FIFinderSyncController.isExtensionEnabled
    }

    private var loginItemDescription: String {
        switch preferences.loginItemStatus {
        case .notRegistered:
            "随当前用户登录自动启动 SvnDock。"
        case .enabled:
            "已开启，下次登录此 Mac 时会自动启动。"
        case .requiresApproval:
            "等待系统允许。请在系统设置的登录项中允许 SvnDock。"
        case .notFound:
            "暂未获取系统登录项状态。可尝试开启，未成功时会显示具体原因。"
        }
    }
}
