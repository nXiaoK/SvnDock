import AppKit
import SwiftUI

struct SvnDockSettingsView: View {
    @ObservedObject var preferences: SvnDockPreferences

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
                LabeledContent("Finder 集成") {
                    Text("在“系统设置 → 通用 → 登录项与扩展 → Finder 扩展”中启用")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .tint(SvnDockTheme.accent)
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { preferences.refreshLoginItemStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            preferences.refreshLoginItemStatus()
        }
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
