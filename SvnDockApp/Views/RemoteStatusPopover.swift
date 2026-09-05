import SwiftUI

struct RemoteStatusPopover: View {
    @ObservedObject var store: SvnDockStore

    private var state: SvnDockRemoteStatusState { store.selectedRemoteStatus }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("服务器更新")
                        .font(.system(size: 16, weight: .semibold))
                    Text(store.selectedWorkingCopy?.name ?? "工作副本")
                        .font(.system(size: 12))
                        .foregroundStyle(SvnDockTheme.secondaryText)
                }
                Spacer()
                if state.isChecking {
                    ProgressView().controlSize(.small)
                }
                Button(state.snapshot == nil ? "检查服务器更新" : "重新检查") {
                    Task { await store.checkSelectedRemoteStatus() }
                }
                .disabled(store.selectedWorkingCopy == nil || store.isInteractionBlocked || state.isChecking)
            }

            Text("检查当前工作副本范围内的传入变化，不会更新本地文件。")
                .font(.system(size: 12))
                .foregroundStyle(SvnDockTheme.secondaryText)

            if let message = state.lastError {
                Label("检查失败：\(message)", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(SvnDockTheme.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let snapshot = state.snapshot {
                VStack(alignment: .leading, spacing: 5) {
                    Text("检查时间：\(snapshot.checkedAt.formatted(date: .abbreviated, time: .standard))")
                    if state.showsPreviousResult {
                        Label("以下为上次结果，需重新检查后确认。", systemImage: "clock.arrow.circlepath")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(SvnDockTheme.secondaryText)

                Divider()
                if snapshot.entries.isEmpty {
                    Label("上次检查未发现服务器更新", systemImage: "checkmark.circle")
                        .font(.system(size: 13))
                        .padding(.vertical, 12)
                } else {
                    Text("\(snapshot.entries.count) 个路径有服务器更新")
                        .font(.system(size: 12, weight: .medium))
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(snapshot.entries) { entry in
                                HStack(alignment: .top, spacing: 12) {
                                    Text(verbatim: entry.displayName)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                        .help(entry.relativePath)
                                    Spacer(minLength: 8)
                                    Text(entry.changeDescription)
                                        .foregroundStyle(SvnDockTheme.secondaryText)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                .font(.system(size: 12))
                                .padding(.vertical, 8)
                                Divider()
                            }
                        }
                    }
                    .frame(height: min(CGFloat(snapshot.entries.count) * 45, 240))
                }
                Text("结果仅代表检查时的状态；本地变更与服务器更新分别显示。")
                    .font(.system(size: 11))
                    .foregroundStyle(SvnDockTheme.secondaryText)
            } else if !state.isChecking && state.lastError == nil {
                Label("尚未检查服务器", systemImage: "network")
                    .font(.system(size: 13))
                    .padding(.vertical, 12)
            }
        }
        .padding(20)
        .frame(width: 480)
        .foregroundStyle(SvnDockTheme.text)
        .background(SvnDockTheme.surface)
    }
}
