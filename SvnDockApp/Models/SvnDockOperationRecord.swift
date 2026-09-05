import Foundation

/// A completed operation observed during this application session. Its outcome
/// is supplied by the executor; the presentation never infers success from text.
struct SvnDockOperationRecord: Identifiable, Equatable, Sendable {
    enum Outcome: String, Equatable, Sendable {
        case success
        case failure
        case uncertain

        var displayName: String {
            switch self {
            case .success: "完成"
            case .failure: "失败"
            case .uncertain: "结果待确认"
            }
        }

        var symbol: String {
            switch self {
            case .success: "checkmark.circle"
            case .failure: "exclamationmark.circle"
            case .uncertain: "questionmark.circle"
            }
        }
    }

    static let maximumCount = 30

    let id: UUID
    let workingCopyID: UUID
    let workingCopyName: String
    let actionTitle: String
    let startedAt: Date
    let finishedAt: Date
    let outcome: Outcome
    let summary: String
    let detail: String?

    init(
        id: UUID = UUID(),
        workingCopy: SvnDockWorkingCopy,
        actionTitle: String,
        startedAt: Date,
        finishedAt: Date = Date(),
        outcome: Outcome,
        summary: String,
        detail: String? = nil
    ) {
        self.id = id
        workingCopyID = workingCopy.id
        workingCopyName = workingCopy.name
        self.actionTitle = actionTitle
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.summary = summary
        self.detail = detail.map(Self.redactingSensitiveDetails)
    }

    /// Latest completion first. Replacing a record cannot consume two slots.
    static func prepending(_ record: Self, to existing: [Self]) -> [Self] {
        [record] + existing.lazy.filter { $0.id != record.id }.prefix(maximumCount - 1)
    }

    var copyText: String {
        var lines = [
            "\(actionTitle) · \(workingCopyName)",
            "结果：\(outcome.displayName)",
            "开始：\(startedAt.formatted(.iso8601))",
            "结束：\(finishedAt.formatted(.iso8601))",
            summary
        ]
        if let detail, !detail.isEmpty { lines.append(detail) }
        return lines.joined(separator: "\n")
    }

    /// Redact before retaining the detail so both the UI and clipboard receive
    /// the same safe value. Keep repository hosts and paths useful for diagnosis.
    private static func redactingSensitiveDetails(_ detail: String) -> String {
        let patterns: [(String, String)] = [
            // Usernames and passwords in URL authority, including percent
            // encoded credentials and svn+ssh URLs with a username only.
            (#"(?i)([a-z][a-z0-9+.-]*://)[^\s/?#\"'<>]+@"#, "$1[已隐藏]@"),
            // Headers with an authentication scheme have a two-part value.
            // Handle these first so hiding "Bearer" cannot leave its token.
            (#"(?i)(?<![\w])((?:[\"']?authorization[\"']?[ \t]*[:=][ \t]*|--authorization[ \t]+))[a-z][a-z0-9_-]*[ \t]+[^\s&;,}\"']+"#, "$1[已隐藏]"),
            // URL/query assignments, JSON/config values, and command options.
            // Quoted values may contain spaces or escaped quote characters.
            (#"(?i)(?<![\w])((?:--)?[\"']?(?:password|passwd|token|access_token|api_key|authorization)[\"']?\s*[:=]\s*|--(?:password|passwd|token|access_token|api_key|authorization)[ \t]+)(?:\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|[^\s&;,}\"']+)"#, "$1[已隐藏]")
        ]
        var redacted = detail
        for (pattern, replacement) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                // A future malformed redaction rule must not expose raw output.
                return "详细信息不可显示（脱敏处理失败）。"
            }
            redacted = expression.stringByReplacingMatches(
                in: redacted, range: NSRange(redacted.startIndex..., in: redacted),
                withTemplate: replacement
            )
        }
        return redacted
    }
}
