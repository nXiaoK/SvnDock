import SwiftUI

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
        case .modified: .blue
        case .added: .green
        case .deleted, .missing: .red
        case .replaced: .indigo
        case .conflicted, .obstructed: .orange
        case .unversioned: .yellow
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
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
