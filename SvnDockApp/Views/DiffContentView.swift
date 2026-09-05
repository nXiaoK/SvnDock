import AppKit
import SwiftUI
import SvnDockCore

enum DiffDisplayMode: String, CaseIterable, Identifiable {
    case unified, sideBySide, raw

    var id: Self { self }
    var title: String {
        switch self {
        case .unified: "合并"
        case .sideBySide: "并排"
        case .raw: "原文"
        }
    }
}

struct DiffPresentation: Sendable {
    struct Item: Identifiable, Sendable {
        enum ID: Hashable, Sendable {
            case hunk(Int)
            case line(Int)
        }
        enum Content: Sendable {
            case hunk(Int)
            case line(hunk: Int, row: Int, kind: UnifiedDiffRowKind)
        }
        let id: ID
        let content: Content
    }

    let document: UnifiedDiffDocument
    let unifiedItems: [Item]
    let sideBySideItems: [Item]
    let additions: Int
    let deletions: Int

    init(text: String) {
        document = UnifiedDiffParser.parse(text)
        var unified: [Item] = []
        var sideBySide: [Item] = []
        var added = 0
        var deleted = 0
        for (index, hunk) in document.hunks.enumerated() {
            guard !Task.isCancelled else { break }
            let header = Item(id: .hunk(index), content: .hunk(index))
            unified.append(header)
            sideBySide.append(header)
            for (rowIndex, row) in hunk.rows.enumerated() {
                sideBySide.append(Item(id: .line(sideBySide.count),
                    content: .line(hunk: index, row: rowIndex, kind: row.kind)))
                if row.kind != .context {
                    if row.oldText != nil { deleted += 1 }
                    if row.newText != nil { added += 1 }
                }
            }
            // Store coordinates into the parsed document, not another two
            // arrays of full row values. Unified blocks still list every
            // deletion before their additions, as in the original patch.
            var rowIndex = 0
            while rowIndex < hunk.rows.count {
                if hunk.rows[rowIndex].kind == .context {
                    unified.append(Item(id: .line(unified.count),
                        content: .line(hunk: index, row: rowIndex, kind: .context)))
                    rowIndex += 1
                    continue
                }
                let start = rowIndex
                while rowIndex < hunk.rows.count, hunk.rows[rowIndex].kind != .context {
                    rowIndex += 1
                }
                for offset in start..<rowIndex where hunk.rows[offset].oldText != nil {
                    unified.append(Item(id: .line(unified.count),
                        content: .line(hunk: index, row: offset, kind: .deletion)))
                }
                for offset in start..<rowIndex where hunk.rows[offset].newText != nil {
                    unified.append(Item(id: .line(unified.count),
                        content: .line(hunk: index, row: offset, kind: .addition)))
                }
            }
        }
        unifiedItems = unified
        sideBySideItems = sideBySide
        additions = added
        deletions = deleted
    }

    func row(hunk: Int, index: Int, kind: UnifiedDiffRowKind) -> UnifiedDiffRow {
        let row = document.hunks[hunk].rows[index]
        guard kind != row.kind else { return row }
        return UnifiedDiffRow(
            oldLineNumber: kind == .deletion ? row.oldLineNumber : nil,
            newLineNumber: kind == .addition ? row.newLineNumber : nil,
            oldText: kind == .deletion ? row.oldText : nil,
            newText: kind == .addition ? row.newText : nil,
            kind: kind,
            oldHasTrailingNewline: kind == .deletion ? row.oldHasTrailingNewline : true,
            newHasTrailingNewline: kind == .addition ? row.newHasTrailingNewline : true
        )
    }
}

struct DiffStatistics: Equatable, Sendable {
    let additions: Int
    let deletions: Int
    let hunks: Int
}

/// One parsed document supplies both the code view and the inspector summary.
@MainActor
final class DiffPresentationModel: ObservableObject {
    @Published private(set) var presentation: DiffPresentation?
    private var generation = 0

    var statistics: DiffStatistics? {
        presentation.map {
            DiffStatistics(additions: $0.additions, deletions: $0.deletions, hunks: $0.document.hunks.count)
        }
    }

    func clear() {
        generation += 1
        presentation = nil
    }

    func load(text: String) async {
        guard !Task.isCancelled else { return }
        clear()
        let requestGeneration = generation
        let worker = Task.detached(priority: .userInitiated) {
            DiffPresentation(text: text)
        }
        await withTaskCancellationHandler {
            let result = await worker.value
            guard !Task.isCancelled, generation == requestGeneration else { return }
            presentation = result
        } onCancel: {
            worker.cancel()
        }
    }
}

/// Both entry points use a vertical, width-constrained document. In particular,
/// no row contains a height-expanding Divider/Rectangle in its layout tree.
struct DiffContentView: View {
    let text: String
    let oldTitle: String
    let newTitle: String
    @State private var mode: DiffDisplayMode
    @StateObject private var presentationModel: DiffPresentationModel
    @State private var selectedHunk = 0
    @State private var fontSize: CGFloat = 12

    init(text: String, initialMode: DiffDisplayMode = .unified,
         oldTitle: String = "BASE · 基础版本", newTitle: String = "工作副本 · 本地修改",
         presentationModel: DiffPresentationModel? = nil) {
        self.text = text
        self.oldTitle = oldTitle
        self.newTitle = newTitle
        _mode = State(initialValue: initialMode)
        _presentationModel = StateObject(wrappedValue: presentationModel ?? DiffPresentationModel())
    }

    var body: some View {
        Group {
            if let presentation = presentationModel.presentation {
                content(presentation)
            } else {
                ProgressView("正在整理差异…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SvnDockTheme.surface, in: Rectangle())
        .task(id: text) {
            selectedHunk = 0
            await presentationModel.load(text: text)
        }
    }

    private func content(_ presentation: DiffPresentation) -> some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                controls(presentation, proxy: proxy)
                VStack(spacing: 0) {
                    if mode == .raw || presentation.document.hunks.isEmpty {
                        if mode != .raw {
                            Text("没有可展示的文本变更，以下为 SVN 输出（可能包含属性或二进制变更）。")
                                .font(.caption)
                                .foregroundStyle(SvnDockTheme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(SvnDockTheme.subtleSurface, in: Rectangle())
                        }
                        DiffRawTextView(text: text, fontSize: fontSize)
                    } else {
                        columnHeaders
                        Divider()
                        ScrollView(.vertical) {
                            // Flatten hunk headers and rows into one lazy sequence.
                            // Nested lazy groups can estimate an entire hunk as one
                            // row and leave later changes outside the visible range.
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(mode == .sideBySide ? presentation.sideBySideItems : presentation.unifiedItems) { item in
                                    switch item.content {
                                    case let .hunk(index):
                                        hunkHeader(presentation.document.hunks[index], index: index)
                                            .id(item.id)
                                    case let .line(hunk, row, kind):
                                        DiffCodeRow(row: presentation.row(hunk: hunk, index: row, kind: kind),
                                                    sideBySide: mode == .sideBySide, fontSize: fontSize)
                                            .id(item.id)
                                    }
                                }
                                if let properties = presentation.document.propertyChanges {
                                    Text(properties)
                                        .font(.system(size: fontSize, design: .monospaced))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(12)
                                        .background(SvnDockTheme.subtleSurface, in: Rectangle())
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .id(mode)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .svnDockSurface(cornerRadius: 9)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func controls(_ presentation: DiffPresentation, proxy: ScrollViewProxy) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                displayModeControl
                Spacer(minLength: 0)
                changeCounts(presentation)
                fontSizeControl
                hunkNavigation(presentation, proxy: proxy)
                copyButton
            }
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    displayModeControl
                    Spacer(minLength: 0)
                    copyButton
                }
                HStack(spacing: 12) {
                    fontSizeControl
                    Spacer(minLength: 0)
                    hunkNavigation(presentation, proxy: proxy)
                }
            }
        }
        .buttonStyle(SvnDockButtonStyle())
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(SvnDockTheme.surface, in: Rectangle())
    }

    private var displayModeControl: some View {
        HStack(spacing: 2) {
            ForEach(DiffDisplayMode.allCases) { displayMode in
                Button {
                    mode = displayMode
                    selectedHunk = 0
                } label: {
                    Text(displayMode.title)
                        .font(.system(size: 12, weight: mode == displayMode ? .semibold : .regular))
                        .foregroundStyle(mode == displayMode ? SvnDockTheme.accent : SvnDockTheme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background {
                            if mode == displayMode {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(SvnDockTheme.surface)
                                    .shadow(color: SvnDockTheme.accent.opacity(0.10), radius: 2, y: 1)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(SvnDockTheme.accent.opacity(0.35), lineWidth: 1)
                                    }
                                    .allowsHitTesting(false)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(SvnDockPlainButtonStyle(cornerRadius: 6))
                .accessibilityLabel("\(displayMode.title)差异")
                .accessibilityAddTraits(mode == displayMode ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(width: 190)
        .background(SvnDockTheme.subtleSurface, in: RoundedRectangle(cornerRadius: 8))
    }

    private var fontSizeControl: some View {
        HStack(spacing: 0) {
            Button {
                fontSize = max(10, fontSize - 1)
            } label: {
                Text("A−")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .disabled(fontSize <= 10)
            .accessibilityLabel("缩小差异字号")
            .help("缩小差异字号")

            Button {
                fontSize = 12
            } label: {
                Text("\(Int(fontSize)) pt")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(SvnDockTheme.secondaryText)
                    .frame(width: 44, height: 30)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("差异字号，\(Int(fontSize)) 点，恢复默认")
            .help("恢复默认字号（12 pt）")

            Button {
                fontSize = min(20, fontSize + 1)
            } label: {
                Text("A+")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .disabled(fontSize >= 20)
            .accessibilityLabel("放大差异字号")
            .help("放大差异字号")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(SvnDockTheme.text)
        .buttonStyle(SvnDockPlainButtonStyle(cornerRadius: 6))
        .padding(3)
        .background(SvnDockTheme.subtleSurface, in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
    }

    @ViewBuilder
    private func changeCounts(_ presentation: DiffPresentation) -> some View {
        if !presentation.document.hunks.isEmpty {
            HStack(spacing: 3) {
                Text("+\(presentation.additions)").foregroundStyle(SvnDockTheme.green)
                Text("−\(presentation.deletions)").foregroundStyle(SvnDockTheme.red)
            }
            .font(.system(size: 11, design: .monospaced))
            .fixedSize()
            .help("新增 \(presentation.additions) 行，删除 \(presentation.deletions) 行")
        }
    }

    @ViewBuilder
    private func hunkNavigation(_ presentation: DiffPresentation, proxy: ScrollViewProxy) -> some View {
        if !presentation.document.hunks.isEmpty {
            HStack(spacing: 8) {
                Button {
                    jump(to: selectedHunk - 1, proxy: proxy)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(mode == .raw || selectedHunk == 0)
                .accessibilityLabel("上一处变更")
                .help("上一处变更")
                Text("\(selectedHunk + 1)/\(presentation.document.hunks.count)")
                    .font(.caption.monospacedDigit())
                    .fixedSize()
                    .foregroundStyle(SvnDockTheme.secondaryText)
                    .help("当前导航位置 / 变更块总数")
                Button {
                    jump(to: selectedHunk + 1, proxy: proxy)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(mode == .raw || selectedHunk + 1 >= presentation.document.hunks.count)
                .accessibilityLabel("下一处变更")
                .help("下一处变更")
            }
            .fixedSize()
        }
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .accessibilityLabel("复制完整差异")
        .help("复制完整差异")
    }

    private func jump(to index: Int, proxy: ScrollViewProxy) {
        selectedHunk = index
        proxy.scrollTo(DiffPresentation.Item.ID.hunk(index), anchor: .top)
    }

    @ViewBuilder
    private var columnHeaders: some View {
        if mode == .sideBySide {
            DiffColumnsLayout {
                Text(oldTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                Text(newTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(SvnDockTheme.secondaryText)
            .padding(.vertical, 10)
            .background(SvnDockTheme.accent.opacity(0.07), in: Rectangle())
        } else {
            HStack(spacing: 0) {
                Text("旧行").frame(width: lineNumberWidth)
                Text("新行").frame(width: lineNumberWidth)
                Text("\(oldTitle) → \(newTitle)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 20)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(SvnDockTheme.secondaryText)
            .padding(.vertical, 10)
            .background(SvnDockTheme.accent.opacity(0.07), in: Rectangle())
        }
    }

    private func hunkHeader(_ hunk: UnifiedDiffHunk, index: Int) -> some View {
        Text("@@ −\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@\(hunk.heading.map { "  \($0)" } ?? "")")
            .font(.system(size: fontSize - 1, design: .monospaced))
            .foregroundStyle(SvnDockTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(SvnDockTheme.accent.opacity(0.055), in: Rectangle())
            .accessibilityLabel("变更 \(index + 1)，旧版第 \(hunk.oldStart) 行，新版第 \(hunk.newStart) 行")
    }

    private var lineNumberWidth: CGFloat { max(36, fontSize * 3) + 8 }
}

/// Measures wrapping against equal finite widths, then places both sides with
/// the same row height so insertions and long replacements remain aligned.
struct DiffColumnsLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(1, proposal.width ?? 600)
        let cellWidth = width / CGFloat(max(1, subviews.count))
        let height = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width / CGFloat(max(1, subviews.count))
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(index) * width, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
        }
    }
}

private struct DiffCodeRow: View {
    let row: UnifiedDiffRow
    let sideBySide: Bool
    let fontSize: CGFloat

    var body: some View {
        Group {
            if sideBySide {
                DiffColumnsLayout {
                    cell(old: true)
                        .overlay(alignment: .trailing) {
                            SvnDockTheme.border.frame(width: 1)
                                .allowsHitTesting(false)
                        }
                    cell(old: false)
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    lineNumber(row.oldLineNumber)
                    lineNumber(row.newLineNumber)
                    code(
                        text: row.newText ?? row.oldText,
                        marker: row.kind == .addition ? "+" : row.kind == .deletion ? "−" : " ",
                        hasNewline: row.kind == .deletion ? row.oldHasTrailingNewline : row.newHasTrailingNewline
                    )
                }
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(tint(old: row.kind == .deletion), in: Rectangle())
            }
        }
        .font(.system(size: fontSize, design: .monospaced))
    }

    private func cell(old: Bool) -> some View {
        let number = old ? row.oldLineNumber : row.newLineNumber
        let changed = row.kind != .context && number != nil
        return HStack(alignment: .top, spacing: 0) {
            lineNumber(number)
            code(
                text: old ? row.oldText : row.newText,
                marker: changed ? (old ? "−" : "+") : " ",
                hasNewline: old ? row.oldHasTrailingNewline : row.newHasTrailingNewline
            )
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tint(old: old), in: Rectangle())
    }

    private func lineNumber(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? " ")
            .font(.system(size: fontSize - 1, design: .monospaced))
            .foregroundStyle(SvnDockTheme.secondaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(width: max(36, fontSize * 3), alignment: .trailing)
            .padding(.trailing, 8)
            .textSelection(.disabled)
    }

    private func code(text: String?, marker: String, hasNewline: Bool) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(marker)
                .foregroundStyle(SvnDockTheme.secondaryText)
                .frame(width: 12)
                .textSelection(.disabled)
            VStack(alignment: .leading, spacing: 2) {
                Text(text.flatMap { $0.isEmpty ? nil : $0 } ?? " ")
                    .foregroundStyle(SvnDockTheme.text)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if text != nil, !hasNewline {
                    Text("文件末尾无换行符")
                        .font(.system(size: 10))
                        .foregroundStyle(SvnDockTheme.secondaryText)
                }
            }
        }
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func tint(old: Bool) -> Color {
        guard row.kind != .context,
              (old ? row.oldText : row.newText) != nil else { return .clear }
        return old ? SvnDockTheme.red.opacity(0.10) : SvnDockTheme.green.opacity(0.11)
    }
}

/// Native selectable text keeps raw patches usable for multiline copy and
/// property/binary output, including extremely long lines.
struct DiffRawTextView: NSViewRepresentable {
    let text: String
    var fontSize: CGFloat = 12

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.textColor = NSColor(SvnDockTheme.text)
        view.backgroundColor = NSColor(SvnDockTheme.surface)
        view.textContainerInset = NSSize(width: 14, height: 14)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.font?.pointSize != fontSize {
            // A zoom change updates the existing document in place. Preserve
            // selection and scroll position instead of replacing its string.
            let selectedRanges = view.selectedRanges
            let scrollOrigin = scroll.contentView.bounds.origin
            view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            view.selectedRanges = selectedRanges
            scroll.contentView.scroll(to: scrollOrigin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        guard view.string != text else { return }
        view.string = text
        view.scrollToBeginningOfDocument(nil)
    }
}
