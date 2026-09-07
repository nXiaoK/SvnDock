import SwiftUI

struct IgnoreRecommendationsSheet: View {
    @ObservedObject var store: SvnDockStore
    let workingCopy: SvnDockWorkingCopy
    @Environment(\.dismiss) private var dismiss
    @State private var plan: SvnDockIgnoreRecommendationPlan?
    @State private var selectedIDs = Set<String>()
    @State private var error: String?
    @State private var scanID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.system(size: 24)).foregroundStyle(SvnDockTheme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("推荐忽略项").font(.system(size: 21, weight: .semibold))
                    Text(workingCopy.name + " · 识别工具配置、依赖和构建输出")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { plan = nil; error = nil; scanID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                    .help("重新扫描").disabled(plan == nil && error == nil)
            }
            .padding(24)
            Divider()
            if let plan {
                HStack {
                    Text("发现 \(plan.items.count) 项 · 已扫描 \(plan.scannedDirectories) 个目录")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(selectedIDs.count == plan.items.count ? "取消全选" : "全选") {
                        selectedIDs = selectedIDs.count == plan.items.count ? [] : Set(plan.items.map(\.id))
                    }.disabled(plan.items.isEmpty)
                }
                .font(.system(size: 12)).padding(.horizontal, 24).padding(.vertical, 12)
                if plan.isPartial {
                    Label("已达到扫描范围限制或部分目录不可读；以下为已检查的结果。", systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 24).padding(.bottom, 8)
                }
                if plan.items.isEmpty {
                    SvnDockEmptyState(symbol: "checkmark.shield", title: "没有需要添加的推荐项",
                        message: "常见工具配置和生成目录不存在、已被忽略或已纳管时，不会重复推荐。")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(plan.items) { item in
                                Toggle(isOn: Binding(get: { selectedIDs.contains(item.id) }, set: { included in
                                    if included { selectedIDs.insert(item.id) } else { selectedIDs.remove(item.id) }
                                })) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text(item.rule.targetRelativePath)
                                                .font(.system(size: 13, weight: .medium)).lineLimit(2).truncationMode(.middle)
                                            Spacer(minLength: 8)
                                            Text(item.project).font(.system(size: 10)).foregroundStyle(SvnDockTheme.accent)
                                                .padding(.horizontal, 7).padding(.vertical, 3)
                                                .background(SvnDockTheme.selection, in: Capsule())
                                        }
                                        Text(item.reason).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .padding(.vertical, 12)
                                Divider()
                            }
                        }.padding(.horizontal, 24)
                    }
                }
            } else if let error {
                SvnDockEmptyState(symbol: "exclamationmark.triangle", title: "扫描未完成", message: error,
                    actionTitle: "重新扫描") { self.error = nil; scanID = UUID() }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在识别项目和可忽略目录…").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("文件保留在磁盘上。规则合并到各父目录的 svn:ignore；必要时仅添加父目录链，属性变更需另行提交。")
                Text("仅推荐当前存在的未纳管项目。请取消勾选需要纳管的自定义目录；已有规则和已纳管文件保留。")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 24).padding(.top, 14)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Text("已选择 \(selectedIDs.count) 项").font(.system(size: 12)).foregroundStyle(.secondary)
                Button("一键添加忽略项") {
                    if let plan { store.confirmIgnoreRecommendations(plan, selectedIDs: selectedIDs) }
                }
                .buttonStyle(SvnDockButtonStyle(primary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(plan == nil || selectedIDs.isEmpty)
            }.padding(24)
        }
        .frame(width: 650, height: 620)
        .background(SvnDockTheme.surface)
        .task(id: scanID) {
            do {
                let result = try await store.prepareIgnoreRecommendations(in: workingCopy)
                try Task.checkCancellation()
                plan = result
                selectedIDs = Set(result.items.map(\.id))
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
