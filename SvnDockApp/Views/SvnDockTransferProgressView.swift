import SwiftUI

/// Observe progress independently of the store so streamed SVN output does
/// not repeatedly rebuild the commit sheet's potentially large selection.
struct SvnDockTransferProgressView: View {
    @ObservedObject var model: SvnDockTransferProgressModel
    var requiredKind: SvnDockOperationKind? = nil

    var body: some View {
        if let progress = model.snapshot,
           requiredKind == nil || requiredKind == progress.kind {
            content(progress)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(SvnDockTheme.accent.opacity(0.055))
                .overlay(alignment: .bottom) { Divider().overlay(SvnDockTheme.border) }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("operation.transferProgress")
        }
    }

    private func content(_ progress: SvnDockTransferProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(progress.kind == .committing ? "正在提交" : "正在更新")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SvnDockTheme.accent)
                Text(bounded(progress.phase, limit: 120))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("operation.transferPhase")
                Spacer(minLength: 12)
                elapsedTime(since: progress.startedAt)
            }
            HStack(spacing: 12) {
                Text(bounded(progress.workingCopyName, limit: 120))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .leading)
                if progress.totalWorkingCopies > 1 {
                    Text("工作副本 \(min(progress.completedWorkingCopies + 1, progress.totalWorkingCopies))/\(progress.totalWorkingCopies) · 已处理 \(progress.completedWorkingCopies)")
                        .fixedSize()
                }
                Spacer(minLength: 0)
                Text("SVN 已报告 \(progress.processedItems) 项")
                    .monospacedDigit()
                    .fixedSize()
                    .accessibilityIdentifier("operation.transferProcessedItems")
                if let selectedCount = progress.selectedItemCount {
                    Text("本次选择 \(selectedCount) 项")
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(SvnDockTheme.secondaryText)
            .help("项数来自 SVN 实时报告的路径通知，并不表示上传完成。目录可能只报告一项，因此它不代表整个传输的完成百分比。")

            Text(progress.currentPath.map { bounded($0, limit: 360) }
                 ?? (progress.processedItems > 0 ? "暂无新的路径通知" : "等待 SVN 路径通知…"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(SvnDockTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("operation.transferPath")

            if progress.totalWorkingCopies > 1 {
                ProgressView(value: Double(progress.completedWorkingCopies), total: Double(progress.totalWorkingCopies))
                    .progressViewStyle(.linear)
                    .tint(SvnDockTheme.accent)
                    .accessibilityLabel("已处理工作副本")
                    .accessibilityValue("\(progress.completedWorkingCopies)/\(progress.totalWorkingCopies)")
            }
        }
        .foregroundStyle(SvnDockTheme.text)
    }

    private func elapsedTime(since start: Date) -> some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(start)))
            Text("已用时 \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(SvnDockTheme.secondaryText)
                .fixedSize()
                .accessibilityIdentifier("operation.transferElapsedTime")
        }
    }

    private func bounded(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let half = (limit - 1) / 2
        return String(value.prefix(half)) + "…" + String(value.suffix(half))
    }
}
