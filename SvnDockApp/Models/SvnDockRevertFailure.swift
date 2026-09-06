import Foundation

struct SvnDockRevertFailure: Error, LocalizedError, Sendable {
    let completedPaths: [String]
    let unconfirmedPaths: [String]
    let wasCancelled: Bool
    let detail: String

    var errorDescription: String? {
        let completed = completedPaths.isEmpty ? "没有确认完成的项目" : "已完成：\(completedPaths.joined(separator: "、"))"
        return "还原未全部完成，部分文件可能已经改变。\n\(completed)\n尚未确认完成：\(unconfirmedPaths.joined(separator: "、"))\n未自动重试，请检查刷新后的状态。\n\(detail)"
    }
}
