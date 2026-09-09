import Foundation
import SvnDockCore

struct SvnDockCommitCommandRequest: Identifiable, Sendable {
    let id = UUID()
    let workingCopy: SvnDockWorkingCopy
    let relativePaths: [String]
    let message: String
}

/// Render the invocation template, not a guessed `svn commit -m ...` command.
/// ProcessRunner chooses private temporary filenames only when it launches SVN.
struct SvnDockCommitCommandPreview: Sendable {
    let invocation: ProcessInvocation
    let commandLine: String
    let fullText: String
    let displayText: String
    let isTruncated: Bool
    let hasEmptyMessage: Bool

    init(invocation: ProcessInvocation) {
        self.invocation = invocation
        var arguments = invocation.arguments
        for (index, file) in invocation.argumentFiles.enumerated() {
            arguments[file.argumentIndex] = "<临时目标清单 \(index + 1)>"
        }
        commandLine = ([invocation.executableURL.path] + arguments).map(Self.shellQuote).joined(separator: " ")
        let message = String(decoding: invocation.standardInput ?? Data(), as: UTF8.self)
        hasEmptyMessage = message.isEmpty
        var sections = [
            "执行目录\n\(invocation.currentDirectoryURL?.path ?? "（继承当前目录）")",
            "最终提交指令\n\(commandLine)"
        ]
        if !invocation.environment.isEmpty {
            sections.append("环境覆盖\n" + invocation.environment.keys.sorted().map {
                "\($0)=\(Self.shellQuote(invocation.environment[$0]!))"
            }.joined(separator: "\n"))
        }
        sections.append("提交说明（标准输入，传入 /dev/stdin）\n" + (hasEmptyMessage ? "（尚未填写，实际提交前必须填写）" : message))
        for (index, file) in invocation.argumentFiles.enumerated() {
            sections.append("临时目标清单 \(index + 1)（完整文件内容）\n" + String(decoding: file.contents, as: UTF8.self))
        }
        sections.append("说明：临时清单的路径在实际执行时生成，此处使用占位符；这份预览不是可直接粘贴执行的脚本。提交前仍会检查本地状态、目录依赖和仓库身份。")
        fullText = sections.joined(separator: "\n\n")
        // A large selection stays cheap to lay out; explicit copying retains
        // every target and the complete stdin, even beyond the display bound.
        let maximum = 120_000
        isTruncated = fullText.utf8.count > maximum
        displayText = isTruncated ? String(decoding: fullText.utf8.prefix(maximum), as: UTF8.self) : fullText
    }

    static func shellQuote(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:@=+-")
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
