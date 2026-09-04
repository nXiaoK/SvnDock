import Foundation
import SwiftUI
import SvnDockCore

struct SideBySideDiffWindow: View {
    let store: SvnDockStore
    let request: SvnDockDiffRequest

    @State private var document: UnifiedDiffDocument?
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
            } else if let document, !document.hunks.isEmpty {
                SideBySideDiffTable(document: document)
            } else if let fallback = document?.fallbackText,
                      !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(spacing: 12) {
                    Label("没有可并排显示的文本差异", systemImage: "doc.richtext")
                        .font(.headline)
                    Text("该文件可能是二进制文件，或本次变更只包含 SVN 属性。")
                        .foregroundStyle(.secondary)
                    ScrollView([.horizontal, .vertical]) {
                        Text(fallback)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding(20)
            } else {
                ContentUnavailableView(
                    "没有文本差异",
                    systemImage: "checkmark.circle",
                    description: Text("文件内容与 SVN 基线一致。")
                )
            }
        }
        .frame(minWidth: 900, minHeight: 560)
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
        .task(id: reloadID) {
            await loadDiff()
        }
    }

    private func loadDiff() async {
        isLoading = true
        errorMessage = nil

        do {
            let text = try await store.diffText(for: request)
            try Task.checkCancellation()
            let parsed = await Task.detached(priority: .userInitiated) {
                UnifiedDiffParser.parse(text)
            }.value
            try Task.checkCancellation()
            document = parsed
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            document = nil
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}

private struct SideBySideDiffTable: View {
    fileprivate static let columnWidth: CGFloat = 680

    let document: UnifiedDiffDocument

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(document.hunks.indices, id: \.self) { hunkIndex in
                        let hunk = document.hunks[hunkIndex]
                        DiffHunkHeader(hunk: hunk)
                        ForEach(hunk.rows.indices, id: \.self) { rowIndex in
                            SideBySideDiffRow(row: hunk.rows[rowIndex])
                        }
                    }
                } header: {
                    DiffColumnHeaders(
                        oldPath: document.oldFilePath,
                        newPath: document.newFilePath
                    )
                }
            }
            .frame(width: Self.columnWidth * 2 + 1, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct DiffColumnHeaders: View {
    let oldPath: String?
    let newPath: String?

    var body: some View {
        HStack(spacing: 0) {
            column(title: "BASE", path: oldPath)
            Divider()
            column(title: "工作副本", path: newPath)
        }
        .frame(height: 46)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func column(title: String, path: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            if let path, !path.isEmpty {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: SideBySideDiffTable.columnWidth, alignment: .leading)
    }
}

private struct DiffHunkHeader: View {
    let hunk: UnifiedDiffHunk

    var body: some View {
        HStack(spacing: 0) {
            Text("第 \(hunk.oldStart) 行")
                .padding(.horizontal, 10)
                .frame(width: SideBySideDiffTable.columnWidth, alignment: .leading)
            Divider()
            Text("第 \(hunk.newStart) 行\(headingSuffix)")
                .padding(.horizontal, 10)
                .frame(width: SideBySideDiffTable.columnWidth, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(height: 28)
        .background(Color.accentColor.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var headingSuffix: String {
        hunk.heading.map { "  \($0)" } ?? ""
    }
}

private struct SideBySideDiffRow: View {
    let row: UnifiedDiffRow

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            DiffLineCell(
                lineNumber: row.oldLineNumber,
                text: row.oldText,
                hasTrailingNewline: row.oldHasTrailingNewline,
                background: oldBackground
            )
            Divider()
            DiffLineCell(
                lineNumber: row.newLineNumber,
                text: row.newText,
                hasTrailingNewline: row.newHasTrailingNewline,
                background: newBackground
            )
        }
        .overlay(alignment: .bottom) {
            Divider().opacity(0.35)
        }
    }

    private var oldBackground: Color {
        switch row.kind {
        case .change, .deletion:
            Color.red.opacity(0.12)
        case .context, .addition:
            .clear
        }
    }

    private var newBackground: Color {
        switch row.kind {
        case .change, .addition:
            Color.green.opacity(0.12)
        case .context, .deletion:
            .clear
        }
    }
}

private struct DiffLineCell: View {
    let lineNumber: Int?
    let text: String?
    let hasTrailingNewline: Bool
    let background: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(lineNumber.map(String.init) ?? "")
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .trailing)
                .padding(.trailing, 8)
                .textSelection(.disabled)

            Rectangle()
                .fill(Color.secondary.opacity(0.16))
                .frame(width: 1)

            Text(displayText)
                .textSelection(.enabled)
                .padding(.leading, 9)
                .frame(maxWidth: .infinity, alignment: .leading)

            if lineNumber != nil, !hasTrailingNewline {
                Text("无换行")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .background(.quaternary, in: Capsule())
                    .padding(.trailing, 6)
                    .help("文件末尾没有换行符")
            }
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.vertical, 3)
        .frame(width: SideBySideDiffTable.columnWidth, alignment: .leading)
        .frame(minHeight: 23)
        .background(background)
    }

    private var displayText: String {
        guard let text, !text.isEmpty else { return " " }
        return text
    }
}
