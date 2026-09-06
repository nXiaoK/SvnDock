import AppKit
import SwiftUI

struct OperationRecordBar: View {
    @ObservedObject var store: SvnDockStore
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 8) {
                if let latest = store.operationRecords.first {
                    Image(systemName: latest.outcome.symbol)
                        .foregroundStyle(outcomeColor(latest.outcome))
                    Text("\(latest.workingCopyName) · \(latest.summary)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text(latest.finishedAt, style: .time)
                        .foregroundStyle(SvnDockTheme.secondaryText)
                } else {
                    Image(systemName: "clock")
                    Text("本次运行暂无更新、提交或冲突处理记录")
                        .foregroundStyle(SvnDockTheme.secondaryText)
                    Spacer(minLength: 12)
                }
                let failedCount = store.operationRecords.filter { $0.outcome == .failure }.count
                let uncertainCount = store.operationRecords.filter { $0.outcome == .uncertain }.count
                if failedCount > 0 {
                    Label("\(failedCount) 失败", systemImage: "exclamationmark.circle")
                        .foregroundStyle(SvnDockTheme.red)
                        .fixedSize()
                        .help("最近操作记录中的失败次数；点击查看对应工作副本。")
                }
                if uncertainCount > 0 {
                    Label("\(uncertainCount) 待确认", systemImage: "questionmark.circle")
                        .foregroundStyle(.orange)
                        .fixedSize()
                        .help("最近操作记录中仍需检查仓库历史或本地状态的结果。")
                }
                Text("操作记录\(store.operationRecords.isEmpty ? "" : "（\(store.operationRecords.count)）")")
                    .foregroundStyle(SvnDockTheme.accent)
                    .fixedSize()
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SvnDockTheme.accent)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 16)
            .frame(minHeight: 34)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(SvnDockPlainButtonStyle(cornerRadius: 0))
        .background(SvnDockTheme.subtleSurface)
        .help("查看本次运行最近 30 条更新、提交与冲突处理结果")
        .accessibilityIdentifier("operations.showRecords")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            OperationRecordPopover(records: store.operationRecords)
        }
    }
}

struct OperationRecordPopover: View {
    let records: [SvnDockOperationRecord]
    @State private var copiedRecordID: UUID?
    @State private var copyErrorID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("操作记录").font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("本次运行 · 最近 \(SvnDockOperationRecord.maximumCount) 条")
                    .font(.system(size: 11))
                    .foregroundStyle(SvnDockTheme.secondaryText)
            }
            .padding(16)
            Divider().overlay(SvnDockTheme.border)
            if records.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock").font(.system(size: 25, weight: .light))
                    Text("尚无更新、提交或冲突处理结果")
                    Text("完成操作后，可在这里查看每个工作副本的结果与详情。")
                        .font(.system(size: 12))
                        .foregroundStyle(SvnDockTheme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(28)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(records) { record in
                            recordRow(record)
                        }
                    }
                    .padding(16)
                }
                .frame(maxHeight: 410)
            }
        }
        .frame(width: 540)
        .background(SvnDockTheme.surface)
        .foregroundStyle(SvnDockTheme.text)
        .tint(SvnDockTheme.accent)
    }

    private func recordRow(_ record: SvnDockOperationRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(record.outcome.displayName, systemImage: record.outcome.symbol)
                    .foregroundStyle(outcomeColor(record.outcome))
                    .font(.system(size: 11, weight: .medium))
                Text("\(record.actionTitle) · \(record.workingCopyName)")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(record.finishedAt, style: .time)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(SvnDockTheme.secondaryText)
            }
            Text(record.summary)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("详情") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("开始：\(record.startedAt.formatted(date: .abbreviated, time: .standard))\n结束：\(record.finishedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.system(size: 11))
                        .foregroundStyle(SvnDockTheme.secondaryText)
                    if let detail = record.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button {
                            NSPasteboard.general.clearContents()
                            if NSPasteboard.general.setString(record.copyText, forType: .string) {
                                copiedRecordID = record.id
                                copyErrorID = nil
                            } else {
                                copyErrorID = record.id
                                copiedRecordID = nil
                            }
                        } label: {
                            Label(copiedRecordID == record.id ? "已复制" : "复制详情",
                                  systemImage: copiedRecordID == record.id ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(SvnDockButtonStyle())
                        if copyErrorID == record.id {
                            Text("无法写入剪贴板，请重试")
                                .font(.system(size: 11))
                                .foregroundStyle(SvnDockTheme.red)
                        }
                        Spacer()
                    }
                }
                .padding(.top, 8)
            }
            .font(.system(size: 11))
        }
        .padding(12)
        .svnDockSurface(cornerRadius: 9)
    }
}

private func outcomeColor(_ outcome: SvnDockOperationRecord.Outcome) -> Color {
    switch outcome {
    case .success: SvnDockTheme.green
    case .failure: SvnDockTheme.red
    case .uncertain: .orange
    }
}
