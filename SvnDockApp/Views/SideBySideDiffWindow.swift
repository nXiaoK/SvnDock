import Foundation
import SwiftUI
import SvnDockCore

struct SideBySideDiffWindow: View {
    private struct LoadID: Equatable {
        let request: SvnDockDiffRequest
        let reloadID: UUID
    }

    let store: SvnDockStore
    let request: SvnDockDiffRequest

    @State private var diffText = ""
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var reloadID = UUID()

    var body: some View {
        Group {
            if isLoading {
                ProgressView("正在读取文件差异…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("无法读取差异", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") {
                        reloadID = UUID()
                    }
                }
            } else if !diffText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DiffContentView(text: diffText, initialMode: .sideBySide)
            } else {
                ContentUnavailableView(
                    "没有文本差异",
                    systemImage: "checkmark.circle",
                    description: Text("文件内容与 SVN 基线一致。")
                )
            }
        }
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("\(request.fileName) — 文件差异")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    reloadID = UUID()
                } label: {
                    Label("重新载入", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .task(id: LoadID(request: request, reloadID: reloadID)) {
            await loadDiff()
        }
    }

    private func loadDiff() async {
        isLoading = true
        errorMessage = nil

        do {
            let text = try await store.diffText(for: request)
            try Task.checkCancellation()
            diffText = text
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            diffText = ""
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}
