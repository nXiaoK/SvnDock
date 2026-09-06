import Foundation

enum SvnDockResolveVerificationError: Error, LocalizedError, Equatable, Sendable {
    case remainingConflicts(paths: [String])
    case statusUnavailable(detail: String)

    var errorDescription: String? {
        switch self {
        case let .remainingConflicts(paths):
            "解决冲突命令已执行，但以下项目仍有冲突：\n\(paths.joined(separator: "\n"))\n请刷新并核实各项结果，再决定下一步；软件未自动重试。"
        case let .statusUnavailable(detail):
            "解决冲突命令已执行，但未能核实最终状态。请刷新并检查所选项目；软件未自动重试。\n\(detail)"
        }
    }
}
