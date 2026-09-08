import Foundation

public enum UnifiedDiffRowKind: String, Hashable, Sendable {
    case context
    case change
    case deletion
    case addition
}

/// One visually aligned row in a side-by-side unified diff.
///
/// Context and replacement rows contain values on both sides. Insertions and
/// deletions leave the absent side `nil`, allowing a renderer to reserve the
/// matching empty row without reconstructing change blocks itself.
public struct UnifiedDiffRow: Hashable, Sendable {
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
    public let oldText: String?
    public let newText: String?
    public let kind: UnifiedDiffRowKind
    public let oldHasTrailingNewline: Bool
    public let newHasTrailingNewline: Bool

    public init(
        oldLineNumber: Int?,
        newLineNumber: Int?,
        oldText: String?,
        newText: String?,
        kind: UnifiedDiffRowKind,
        oldHasTrailingNewline: Bool = true,
        newHasTrailingNewline: Bool = true
    ) {
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.oldText = oldText
        self.newText = newText
        self.kind = kind
        self.oldHasTrailingNewline = oldHasTrailingNewline
        self.newHasTrailingNewline = newHasTrailingNewline
    }
}

public struct UnifiedDiffHunk: Hashable, Sendable {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let heading: String?
    public let rows: [UnifiedDiffRow]

    public init(
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        heading: String?,
        rows: [UnifiedDiffRow]
    ) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.heading = heading
        self.rows = rows
    }

    /// Unified patches list all removals before all insertions in a change
    /// block. Expanding aligned pairs one at a time would scramble that order.
    public var unifiedRows: [UnifiedDiffRow] {
        var result: [UnifiedDiffRow] = []
        var changes: [UnifiedDiffRow] = []
        func flush() {
            for row in changes where row.oldText != nil {
                result.append(UnifiedDiffRow(
                    oldLineNumber: row.oldLineNumber, newLineNumber: nil,
                    oldText: row.oldText, newText: nil, kind: .deletion,
                    oldHasTrailingNewline: row.oldHasTrailingNewline
                ))
            }
            for row in changes where row.newText != nil {
                result.append(UnifiedDiffRow(
                    oldLineNumber: nil, newLineNumber: row.newLineNumber,
                    oldText: nil, newText: row.newText, kind: .addition,
                    newHasTrailingNewline: row.newHasTrailingNewline
                ))
            }
            changes.removeAll(keepingCapacity: true)
        }
        for row in rows {
            if row.kind == .context {
                flush()
                result.append(row)
            } else {
                changes.append(row)
            }
        }
        flush()
        return result
    }
}

public struct UnifiedDiffDocument: Hashable, Sendable {
    public let oldFilePath: String?
    public let newFilePath: String?
    public let hunks: [UnifiedDiffHunk]

    /// The original command output when it contains no parseable text hunks.
    ///
    /// SVN uses non-hunk output for binary and property-only changes. Keeping
    /// that output lets the UI fall back to its existing plain-text viewer.
    public let fallbackText: String?

    /// Property changes accompanying text hunks must remain visible as well.
    public let propertyChanges: String?

    public init(
        oldFilePath: String?,
        newFilePath: String?,
        hunks: [UnifiedDiffHunk],
        fallbackText: String?,
        propertyChanges: String? = nil
    ) {
        self.oldFilePath = oldFilePath
        self.newFilePath = newFilePath
        self.hunks = hunks
        self.fallbackText = fallbackText
        self.propertyChanges = propertyChanges
    }

    public var rows: [UnifiedDiffRow] {
        hunks.flatMap(\.rows)
    }
}

public enum UnifiedDiffParser {
    /// Cancellation returns the original patch as a fallback, never a partial
    /// document that could appear to contain all of the requested changes.
    public static func parse(_ text: String) -> UnifiedDiffDocument {
        guard !Task.isCancelled else {
            return UnifiedDiffDocument(oldFilePath: nil, newFilePath: nil,
                                       hunks: [], fallbackText: text)
        }
        var lines = LineCursor(text)
        var oldFilePath: String?
        var newFilePath: String?
        var hunks: [UnifiedDiffHunk] = []
        var propertyChanges: String?
        var hasFileSection = false
        var inspectedLines = 0

        func fallback() -> UnifiedDiffDocument {
            UnifiedDiffDocument(
                oldFilePath: oldFilePath, newFilePath: newFilePath,
                hunks: [], fallbackText: text
            )
        }

        while let line = lines.current {
            if inspectedLines.isMultiple(of: 256), Task.isCancelled { return fallback() }
            inspectedLines += 1
            if line.hasPrefix("Index: ") || line.hasPrefix("diff --git ") {
                // This model represents one file. A directory diff must retain
                // its file boundaries in the plain-text viewer.
                if hasFileSection { return fallback() }
                hasFileSection = true
            }

            if line.hasPrefix("Property changes on: ") {
                propertyChanges = lines.remainingText.replacingOccurrences(of: "\r\n", with: "\n")
                break
            }

            if line.hasPrefix("--- ") {
                if oldFilePath != nil { return fallback() }
                oldFilePath = filePath(fromHeader: line)
                lines.advance()
                continue
            }

            if line.hasPrefix("+++ ") {
                if newFilePath != nil { return fallback() }
                newFilePath = filePath(fromHeader: line)
                lines.advance()
                continue
            }

            guard let header = parseHunkHeader(line) else {
                if line.hasPrefix("@@") { return fallback() }
                lines.advance()
                continue
            }

            lines.advance()
            let result = parseHunk(&lines, header: header)
            guard result.isComplete else {
                // A truncated/malformed patch must never look like a complete
                // comparison with some changes silently omitted.
                return fallback()
            }
            if !result.rows.isEmpty {
                hunks.append(UnifiedDiffHunk(
                    oldStart: header.oldStart,
                    oldCount: header.oldCount,
                    newStart: header.newStart,
                    newCount: header.newCount,
                    heading: header.heading,
                    rows: result.rows
                ))
            }
        }

        guard !Task.isCancelled else { return fallback() }
        return UnifiedDiffDocument(
            oldFilePath: oldFilePath,
            newFilePath: newFilePath,
            hunks: hunks,
            fallbackText: hunks.isEmpty ? text : nil,
            propertyChanges: propertyChanges
        )
    }
}

private extension UnifiedDiffParser {
    struct HunkHeader {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        let heading: String?
    }

    struct SideLine {
        let number: Int
        let text: String
        var hasTrailingNewline = true
    }

    enum LastParsedLine {
        case context(rowIndex: Int)
        case deletion(pendingIndex: Int)
        case addition(pendingIndex: Int)
    }

    struct HunkResult {
        let rows: [UnifiedDiffRow]
        let isComplete: Bool
    }

    /// Reads slices of the original text without allocating a normalized copy
    /// and a second copy of every line before constructing the output rows.
    struct LineCursor {
        private let text: String
        private var nextIndex: String.Index
        private(set) var current: Substring?

        init(_ text: String) {
            self.text = text
            nextIndex = text.startIndex
            advance()
        }

        var remainingText: Substring {
            text[(current?.startIndex ?? text.endIndex)...]
        }

        mutating func advance() {
            guard nextIndex < text.endIndex else {
                current = nil
                return
            }
            let start = nextIndex
            if let newline = text.unicodeScalars[start...].firstIndex(of: "\n") {
                var end = newline
                if end > start {
                    let previous = text.unicodeScalars.index(before: end)
                    if text.unicodeScalars[previous] == "\r" { end = previous }
                }
                current = text[start..<end]
                nextIndex = text.unicodeScalars.index(after: newline)
            } else {
                current = text[start...]
                nextIndex = text.endIndex
            }
        }
    }

    static func filePath(fromHeader line: Substring) -> String {
        var value = String(line.dropFirst(4))

        if let tab = value.firstIndex(of: "\t") {
            value = String(value[..<tab])
        } else if let revision = value.range(of: " (revision ", options: .backwards) {
            value = String(value[..<revision.lowerBound])
        } else if value.hasSuffix(" (working copy)") {
            value.removeLast(" (working copy)".count)
        }

        return value
    }

    static func parseHunkHeader(_ line: Substring) -> HunkHeader? {
        guard line.hasPrefix("@@") else { return nil }

        let descriptorStart = line.index(line.startIndex, offsetBy: 2)
        guard let closingRange = line.range(
            of: " @@",
            range: descriptorStart..<line.endIndex
        ) else {
            return nil
        }

        let descriptor = line[descriptorStart..<closingRange.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        let ranges = descriptor.split(whereSeparator: { $0.isWhitespace })
        guard ranges.count == 2,
              let oldRange = parseLineRange(String(ranges[0]), prefix: "-"),
              let newRange = parseLineRange(String(ranges[1]), prefix: "+") else {
            return nil
        }

        let rawHeading = line[closingRange.upperBound...]
            .trimmingCharacters(in: .whitespaces)

        return HunkHeader(
            oldStart: oldRange.start,
            oldCount: oldRange.count,
            newStart: newRange.start,
            newCount: newRange.count,
            heading: rawHeading.isEmpty ? nil : rawHeading
        )
    }

    static func parseLineRange(_ value: String, prefix: Character) -> (start: Int, count: Int)? {
        guard value.first == prefix else { return nil }
        let components = value.dropFirst().split(
            separator: ",",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let startValue = components.first,
              let start = Int(startValue),
              start >= 0 else {
            return nil
        }

        let count: Int
        if components.count == 1 {
            count = 1
        } else {
            guard let parsedCount = Int(components[1]), parsedCount >= 0 else {
                return nil
            }
            count = parsedCount
        }

        // The parser increments the line number after every consumed row.
        // Reject ranges that would overflow instead of crashing on patch text.
        guard count <= Int.max - start else { return nil }
        return (start, count)
    }

    static func parseHunk(
        _ lines: inout LineCursor,
        header: HunkHeader
    ) -> HunkResult {
        var rows: [UnifiedDiffRow] = []
        var pendingDeletions: [SideLine] = []
        var pendingAdditions: [SideLine] = []
        var oldLineNumber = header.oldStart
        var newLineNumber = header.newStart
        var oldConsumed = 0
        var newConsumed = 0
        var lastParsedLine: LastParsedLine?

        func flushChangeBlock() -> Bool {
            let rowCount = max(pendingDeletions.count, pendingAdditions.count)
            guard rowCount > 0 else { return !Task.isCancelled }

            for offset in 0..<rowCount {
                if offset.isMultiple(of: 256), Task.isCancelled { return false }
                let deletion = pendingDeletions.indices.contains(offset)
                    ? pendingDeletions[offset]
                    : nil
                let addition = pendingAdditions.indices.contains(offset)
                    ? pendingAdditions[offset]
                    : nil
                let kind: UnifiedDiffRowKind
                if deletion != nil, addition != nil {
                    kind = .change
                } else if deletion != nil {
                    kind = .deletion
                } else {
                    kind = .addition
                }

                rows.append(UnifiedDiffRow(
                    oldLineNumber: deletion?.number,
                    newLineNumber: addition?.number,
                    oldText: deletion?.text,
                    newText: addition?.text,
                    kind: kind,
                    oldHasTrailingNewline: deletion?.hasTrailingNewline ?? true,
                    newHasTrailingNewline: addition?.hasTrailingNewline ?? true
                ))
            }

            pendingDeletions.removeAll(keepingCapacity: true)
            pendingAdditions.removeAll(keepingCapacity: true)
            return true
        }

        func markLastLineWithoutTrailingNewline() {
            switch lastParsedLine {
            case let .context(rowIndex):
                let row = rows[rowIndex]
                rows[rowIndex] = UnifiedDiffRow(
                    oldLineNumber: row.oldLineNumber,
                    newLineNumber: row.newLineNumber,
                    oldText: row.oldText,
                    newText: row.newText,
                    kind: row.kind,
                    oldHasTrailingNewline: false,
                    newHasTrailingNewline: false
                )
            case let .deletion(pendingIndex):
                pendingDeletions[pendingIndex].hasTrailingNewline = false
            case let .addition(pendingIndex):
                pendingAdditions[pendingIndex].hasTrailingNewline = false
            case nil:
                break
            }
        }

        var inspectedLines = 0
        parsingLines: while let line = lines.current {
            if inspectedLines.isMultiple(of: 256), Task.isCancelled {
                return HunkResult(rows: [], isComplete: false)
            }
            inspectedLines += 1
            if line == "\\ No newline at end of file" {
                markLastLineWithoutTrailingNewline()
                lines.advance()
                continue
            }

            if oldConsumed >= header.oldCount, newConsumed >= header.newCount {
                break
            }

            guard let marker = line.first else { break }
            let content = String(line.dropFirst())

            switch marker {
            case " ":
                guard oldConsumed < header.oldCount,
                      newConsumed < header.newCount else {
                    break parsingLines
                }
                guard flushChangeBlock() else {
                    return HunkResult(rows: [], isComplete: false)
                }
                rows.append(UnifiedDiffRow(
                    oldLineNumber: oldLineNumber,
                    newLineNumber: newLineNumber,
                    oldText: content,
                    newText: content,
                    kind: .context
                ))
                lastParsedLine = .context(rowIndex: rows.count - 1)
                oldLineNumber += 1
                newLineNumber += 1
                oldConsumed += 1
                newConsumed += 1
                lines.advance()
            case "-":
                guard oldConsumed < header.oldCount else {
                    break parsingLines
                }
                pendingDeletions.append(SideLine(number: oldLineNumber, text: content))
                lastParsedLine = .deletion(pendingIndex: pendingDeletions.count - 1)
                oldLineNumber += 1
                oldConsumed += 1
                lines.advance()
            case "+":
                guard newConsumed < header.newCount else {
                    break parsingLines
                }
                pendingAdditions.append(SideLine(number: newLineNumber, text: content))
                lastParsedLine = .addition(pendingIndex: pendingAdditions.count - 1)
                newLineNumber += 1
                newConsumed += 1
                lines.advance()
            default:
                break parsingLines
            }
        }

        guard flushChangeBlock(), !Task.isCancelled else {
            return HunkResult(rows: [], isComplete: false)
        }
        return HunkResult(
            rows: rows,
            isComplete: oldConsumed == header.oldCount && newConsumed == header.newCount
        )
    }
}
