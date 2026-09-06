import Darwin
import Foundation

struct SvnDockIgnoreRemovalPlan: Hashable, Sendable {
    let workingCopyID: UUID
    let workingCopyRootURL: URL
    let targetRelativePath: String
    let parentRelativePath: String
    let patterns: [String]
    let originalPropertyValue: String
    let updatedPropertyValue: String
    let affectedSiblingPaths: [String]

    var hasWildcardPatterns: Bool {
        patterns.contains { pattern in
            var escaped = false
            for character in pattern {
                if escaped { escaped = false; continue }
                if character == "\\" { escaped = true; continue }
                if "*?[".contains(character) { return true }
            }
            return false
        }
    }

    var scopeSummary: String {
        let scope = hasWildcardPatterns
            ? "通配规则影响同目录所有匹配名称（当前 \(affectedSiblingPaths.count) 项），也影响以后新增的匹配项目。无法只对一个文件取消该通配规则。"
            : "规则影响同目录的同名项目。"
        return scope + "若另有继承或客户端全局规则，项目仍可能被忽略。"
    }

    static func matches(_ pattern: String, name: String) -> Bool {
        // SVN's ignore lists use APR filename globs (case-sensitive, escaping
        // enabled, no special treatment of a leading dot), not regexes.
        pattern.withCString { patternBytes in
            name.withCString { nameBytes in fnmatch(patternBytes, nameBytes, 0) == 0 }
        }
    }

    static func removingMatches(from value: String, name: String) -> (patterns: [String], value: String) {
        var patterns: [String] = []
        var seen = Set<String>()
        var retained = ""
        var start = value.startIndex
        while start < value.endIndex {
            var end = start
            while end < value.endIndex, value[end] != "\n", value[end] != "\r", value[end] != "\r\n" {
                end = value.index(after: end)
            }
            let content = String(value[start..<end])
            var next = end
            if next < value.endIndex { next = value.index(after: next) }
            if !content.isEmpty, matches(content, name: name) {
                if seen.insert(content).inserted { patterns.append(content) }
            } else {
                retained += value[start..<next]
            }
            start = next
        }
        return (patterns, retained)
    }
}

enum SvnDockIgnoreRemovalError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedSource
    case stalePlan
    case stillIgnored
    case verificationUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSource:
            "直接父目录的 svn:ignore 没有匹配规则。项目可能由继承的 svn:global-ignores、客户端配置或上级未纳管目录影响；此处仅支持移除直接父目录的 svn:ignore 规则，请在对应配置中处理。"
        case .stalePlan:
            "忽略规则或目标已经变化，未修改任何属性。请重新查看并确认要移除的规则。"
        case .stillIgnored:
            "已移除确认的直接父目录 svn:ignore 规则，但项目仍被忽略。请检查继承的 svn:global-ignores 或 SVN 客户端配置；软件未自动重试。"
        case let .verificationUnavailable(detail):
            "已写入忽略规则，但无法核实项目的最新状态。请刷新后检查；软件未自动重试。\n\(detail)"
        }
    }
}
