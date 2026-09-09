import AppKit
import SwiftUI

struct CommitCommandPreviewSheet: View {
    @ObservedObject var store: SvnDockStore
    let request: SvnDockCommitCommandRequest
    @Environment(\.dismiss) private var dismiss
    @State private var preview: SvnDockCommitCommandPreview?
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("预览提交指令").font(.title2.bold())
            Text("\(request.workingCopy.name) · 已勾选 \(request.relativePaths.count) 项")
                .foregroundStyle(.secondary)
            Text("根据当前勾选范围和提交说明生成，仅预览，不执行提交。返回修改后可重新预览。")
                .font(.callout).foregroundStyle(.secondary)
            if let preview {
                if preview.hasEmptyMessage {
                    Label("提交说明尚未填写，当前只能预览。", systemImage: "info.circle")
                        .foregroundStyle(.orange)
                }
                DiffRawTextView(text: preview.displayText)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(SvnDockTheme.border))
                    .accessibilityIdentifier("commit.commandPreviewText")
                if preview.isTruncated {
                    Text("内容较长，界面仅展示前一部分；“复制预览”包含全部指令和目标清单。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                Spacer()
            } else {
                ProgressView("正在生成提交指令…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Spacer()
                Button(copied ? "已复制" : "复制预览") {
                    guard let preview else { return }
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(preview.fullText, forType: .string)
                }
                .disabled(preview == nil)
                Button("返回提交") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22).frame(width: 760, height: 560)
        .task(id: request.id) {
            do { preview = try await store.loadCommitCommandPreview(request) }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
