import SwiftUI

/// Shared native surfaces and controls, based on the light blue workspace design.
enum SvnDockTheme {
    static let accent = adaptive(0x2B66FF, dark: 0x8AAEFF)
    static let onAccent = adaptive(0xFFFFFF, dark: 0x152440)
    static let green = adaptive(0x159D43, dark: 0x64D98B)
    static let red = adaptive(0xE94545, dark: 0xFF827C)
    static let text = adaptive(0x202940, dark: 0xE8EDF8)
    static let secondaryText = adaptive(0x5F6C85, dark: 0xA4AFC4)
    static let border = adaptive(0xE4E9F3, dark: 0x353E52)
    static let surface = adaptive(0xFFFFFF, dark: 0x1D2330)
    static let subtleSurface = adaptive(0xF6F8FC, dark: 0x252D3E)
    static let sidebar = adaptive(0xEDF2FA, dark: 0x202838)
    static let selection = adaptive(0xE3ECFF, dark: 0x283F69)

    private static func adaptive(_ light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

struct SvnDockButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        SvnDockButtonBody(label: configuration.label, primary: primary, isPressed: configuration.isPressed)
    }
}

private struct SvnDockButtonBody<Label: View>: View {
    let label: Label
    let primary: Bool
    let isPressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(minWidth: 34, minHeight: 34)
            .contentShape(.interaction, RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(primary ? SvnDockTheme.onAccent : SvnDockTheme.text)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(primary ? SvnDockTheme.accent : SvnDockTheme.surface)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .fill(SvnDockTheme.accent.opacity(isEnabled ? (isPressed ? 0.16 : isHovered ? 0.07 : 0) : 0))
                    .allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(primary ? SvnDockTheme.accent.opacity(0.4)
                                  : isHovered && isEnabled ? SvnDockTheme.accent.opacity(0.4) : SvnDockTheme.border)
                    .allowsHitTesting(false)
            }
            .shadow(color: primary ? SvnDockTheme.accent.opacity(0.13) : .clear, radius: 4, y: 2)
            .opacity(!isEnabled ? 0.42 : isPressed ? 0.8 : 1)
            .onHover { isHovered = $0 }
    }
}

/// Keep bespoke label layouts, but make their complete bounds interactive.
struct SvnDockPlainButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        SvnDockPlainButtonBody(label: configuration.label, cornerRadius: cornerRadius,
                               isPressed: configuration.isPressed)
    }
}

private struct SvnDockPlainButtonBody<Label: View>: View {
    let label: Label
    let cornerRadius: CGFloat
    let isPressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        label
            .contentShape(.interaction, Rectangle())
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(SvnDockTheme.accent.opacity(isEnabled ? (isPressed ? 0.14 : isHovered ? 0.07 : 0) : 0))
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = $0 }
    }
}

extension View {
    func svnDockSurface(cornerRadius: CGFloat = 10) -> some View {
        background(SvnDockTheme.surface, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(SvnDockTheme.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

struct SvnDockFileIcon: View {
    let entry: SvnDockStatusEntry
    var size: CGFloat = 42

    private var isImage: Bool {
        ["svg", "png", "jpg", "jpeg", "gif", "webp", "icns", "pdf"].contains(
            (entry.relativePath as NSString).pathExtension.lowercased()
        )
    }

    private var tint: Color {
        entry.nodeKind == .directory ? SvnDockTheme.accent : isImage ? .purple : SvnDockTheme.accent
    }

    var body: some View {
        Image(systemName: entry.nodeKind == .directory ? "folder.fill" : isImage ? "photo" : "doc.text")
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.065), in: RoundedRectangle(cornerRadius: size * 0.24))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.24)
                    .strokeBorder(tint.opacity(0.05))
                    .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
    }
}

struct SvnDockFolderIcon: View {
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: "folder.fill")
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(LinearGradient(
                colors: [SvnDockTheme.accent, Color(red: 0.35, green: 0.74, blue: 1)],
                startPoint: .top, endPoint: .bottom
            ))
            .shadow(color: SvnDockTheme.accent.opacity(0.10), radius: 2, y: 2)
            .accessibilityHidden(true)
    }
}

struct SvnDockStatusPill: View {
    let status: SvnDockStatusKind

    var body: some View {
        Text(status.displayName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(status.tint.opacity(0.10), in: Capsule())
            .fixedSize()
    }
}

extension SvnDockStatusKind {
    var symbolName: String {
        switch self {
        case .modified: "pencil.circle.fill"
        case .added: "plus.circle.fill"
        case .deleted: "minus.circle.fill"
        case .replaced: "arrow.triangle.2.circlepath.circle.fill"
        case .conflicted: "exclamationmark.octagon.fill"
        case .unversioned: "questionmark.circle.fill"
        case .missing: "questionmark.folder.fill"
        case .ignored: "eye.slash.circle.fill"
        case .external: "arrow.up.right.square.fill"
        case .obstructed: "xmark.octagon.fill"
        case .clean: "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .modified: SvnDockTheme.accent
        case .added: SvnDockTheme.green
        case .deleted, .missing: SvnDockTheme.red
        case .replaced: .indigo
        case .conflicted, .obstructed: SvnDockTheme.red
        case .unversioned: .orange
        case .ignored, .external, .clean: .secondary
        }
    }
}

struct SvnDockStatusLabel: View {
    let status: SvnDockStatusKind

    var body: some View {
        Label(status.displayName, systemImage: status.symbolName)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(status.tint)
    }
}

struct SvnDockCountBadge: View {
    let value: Int
    var tint: Color = .secondary

    var body: some View {
        if value > 0 {
            Text(value, format: .number)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tint.opacity(0.12), in: Capsule())
                .accessibilityLabel("\(value) 项")
        }
    }
}

struct SvnDockEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(SvnDockTheme.accent.opacity(0.75))
                .frame(width: 82, height: 82)
                .background(SvnDockTheme.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: 24))
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(SvnDockTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .foregroundStyle(SvnDockTheme.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
