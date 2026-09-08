import Foundation

/// SVN's command line reports stages and item notifications, but does not
/// provide a trustworthy total byte count or percentage for commit/update.
public enum SVNProgressPhase: Hashable, Sendable {
    case preparing
    case processing
    case transferring
    case awaitingServer
}

public struct SVNProgressSnapshot: Hashable, Sendable {
    public var phase: SVNProgressPhase
    public var processedItemCount: Int
    public var currentPath: String?

    public init(
        phase: SVNProgressPhase = .preparing,
        processedItemCount: Int = 0,
        currentPath: String? = nil
    ) {
        self.phase = phase
        self.processedItemCount = processedItemCount
        self.currentPath = currentPath
    }
}

/// Parses English SVN notifications (the command builder sets an English locale).
/// Byte buffering preserves split UTF-8 characters; no raw stderr or arbitrary
/// output is exposed. Callers serialize access and own terminal success/failure.
public struct SVNProgressParser: Sendable {
    public private(set) var snapshot = SVNProgressSnapshot()
    private var line = [UInt8]()
    private var discardingLine = false
    private static let maximumLineBytes = 16 * 1_024
    private static let transferPrefix = Array("Transmitting file data".utf8)
    private static let committingPrefix = Array("Committing transaction".utf8)

    public init() {}

    /// Returns at most one cumulative snapshot per chunk. Large commands need
    /// neither one task per file nor retention of their notification history.
    public mutating func consume(_ chunk: ProcessOutputChunk) -> SVNProgressSnapshot? {
        guard chunk.stream == .standardOutput else { return nil }
        let previous = snapshot
        for byte in chunk.data {
            if byte == 10 || byte == 13 {
                if !discardingLine, !line.isEmpty { consumeLine() }
                line.removeAll(keepingCapacity: true)
                discardingLine = false
            } else if !discardingLine {
                if line.count < Self.maximumLineBytes {
                    line.append(byte)
                } else {
                    // Do not display a truncated path or grow without bound
                    // when a child prints an enormous unterminated line.
                    line.removeAll(keepingCapacity: true)
                    discardingLine = true
                }
            }
        }
        // SVN emits transmission dots without a terminating newline. Recognize
        // the stage immediately rather than waiting for the final 'done'.
        if line.starts(with: Self.transferPrefix) {
            setPhase(.transferring)
        } else if line.starts(with: Self.committingPrefix) {
            setPhase(.awaitingServer)
        }
        return previous == snapshot ? nil : snapshot
    }

    public mutating func finish() -> SVNProgressSnapshot? {
        let previous = snapshot
        if !discardingLine, !line.isEmpty { consumeLine() }
        line.removeAll(keepingCapacity: true)
        discardingLine = false
        return previous == snapshot ? nil : snapshot
    }

    private mutating func consumeLine() {
        let text = String(decoding: line, as: UTF8.self)
        if text.hasPrefix("Transmitting file data") {
            setPhase(.transferring)
            if text.hasSuffix("done") { setPhase(.awaitingServer) }
            return
        }
        if text.hasPrefix("Committing transaction") || text.hasPrefix("Committed revision ")
            || text.hasPrefix("Updated to revision ") || text.hasPrefix("At revision ") {
            // Even 'Committed revision' is only an informational notification:
            // command exit and post-mutation verification decide completion.
            setPhase(.awaitingServer)
            return
        }
        for verb in ["Adding", "Deleting", "Sending", "Replacing"] {
            guard text.hasPrefix(verb),
                  text.dropFirst(verb.count).first.map({ $0 == " " || $0 == "\t" }) == true else {
                continue
            }
            var path = text.dropFirst(verb.count).drop(while: { $0 == " " || $0 == "\t" })
            if path.hasPrefix("(bin)") {
                path = path.dropFirst(5).drop(while: { $0 == " " || $0 == "\t" })
            }
            recordPath(String(path))
            return
        }
        // svn update: four notification columns followed by one separator.
        // Whitespace in the path after that separator is significant.
        let columns = line.prefix(4)
        let validColumns: Set<UInt8> = [32, 65, 68, 85, 67, 71, 69, 66, 82]
        if line.count > 5, line[4] == 32,
           columns.contains(where: { $0 != 32 }),
           columns.allSatisfy({ validColumns.contains($0) }) {
            recordPath(String(decoding: line.dropFirst(5), as: UTF8.self))
        }
    }

    private mutating func recordPath(_ path: String) {
        guard !path.isEmpty else { return }
        snapshot.phase = .processing
        if snapshot.processedItemCount < Int.max { snapshot.processedItemCount += 1 }
        snapshot.currentPath = Self.redactingPath(path)
    }

    private mutating func setPhase(_ phase: SVNProgressPhase) {
        snapshot.phase = phase
        snapshot.currentPath = nil
    }

    // Match the operation-log privacy rules before retaining user-visible
    // content. This also covers unusual filenames containing credential syntax.
    private static let redactions: [(NSRegularExpression, String)] = [
        (#"(?i)([a-z][a-z0-9+.-]*://)[^\s/?#\"'<>]+@"#, "$1[已隐藏]@"),
        (#"(?i)(?<![\w])((?:[\"']?authorization[\"']?[ \t]*[:=][ \t]*|--authorization[ \t]+))[a-z][a-z0-9_-]*[ \t]+[^\s&;,}\"']+"#, "$1[已隐藏]"),
        (#"(?i)(?<![\w])((?:--)?[\"']?(?:password|passwd|token|access_token|api_key|authorization)[\"']?\s*[:=]\s*|--(?:password|passwd|token|access_token|api_key|authorization)[ \t]+)(?:\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|[^\s&;,}\"']+)"#, "$1[已隐藏]")
    ].compactMap { pattern, replacement in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, replacement) }
    }

    private static func redactingPath(_ path: String) -> String {
        guard redactions.count == 3 else { return "[路径已隐藏]" }
        var result = path
        for (expression, replacement) in redactions {
            result = expression.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement
            )
        }
        return result.count > 1_024 ? String(result.prefix(1_024)) + "…" : result
    }
}
