enum SvnDockDifferenceFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case hideLineEndings
    case hideWhitespace

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: "显示全部差异"
        case .hideLineEndings: "隐藏仅换行符变化"
        case .hideWhitespace: "隐藏仅空白变化"
        }
    }

    var help: String {
        switch self {
        case .all:
            "显示所有 SVN 变更。差异筛选只改变列表显示，保留文件内容和 SVN 状态。"
        case .hideLineEndings:
            "隐藏仅 CRLF、LF 或 CR 换行符不同的文件，保留文件内容和 SVN 状态。从工作区发起提交时，隐藏的文件默认不勾选。"
        case .hideWhitespace:
            "隐藏仅空格、Tab 或换行符不同的文件；这些空白在字符串和缩进中也可能有意义。文件内容和 SVN 状态保持原样，隐藏的文件在提交时默认不勾选。"
        }
    }
}
