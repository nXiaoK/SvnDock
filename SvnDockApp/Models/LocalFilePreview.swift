import Darwin
import Foundation

enum LocalFilePreview: Equatable, Sendable {
    case text(String)
    case tooLarge(limit: Int)
    case binary
    case unsupportedEncoding
    case unsupportedType
    case unavailable(String)

    static let maximumBytes = 1_048_576

    /// Opens each component relative to an already-open directory without
    /// following links. Bounded reads also handle files growing during preview.
    static func read(relativePath: String, rootURL: URL, limit: Int = maximumBytes) -> Self {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard rootURL.isFileURL, limit > 0, limit < Int.max,
              !relativePath.hasPrefix("/"),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".."
                  && $0.lowercased() != ".svn" && !$0.contains("\0") }) else {
            return .unavailable("无法确认文件位于当前工作副本中。请刷新状态后重试。")
        }

        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return .unavailable("无法访问工作副本目录。请检查目录是否仍存在及访问权限。") }
        defer { close(directory) }

        for component in components.dropLast() {
            let child = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { return .unavailable("无法安全访问此路径。目录可能已移动、无权访问或包含符号链接。") }
            close(directory)
            directory = child
        }

        let file = openat(directory, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { return .unavailable("无法读取此文件。文件可能已移动、无权访问或是符号链接。") }
        defer { close(file) }
        var metadata = stat()
        guard fstat(file, &metadata) == 0 else { return .unavailable("无法读取文件信息，请刷新后重试。") }
        guard metadata.st_mode & S_IFMT == S_IFREG else { return .unsupportedType }
        guard metadata.st_size <= limit else { return .tooLarge(limit: limit) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(65_536, limit + 1))
        while data.count <= limit {
            guard !Task.isCancelled else { return .unavailable("预览已取消。") }
            let amount = min(buffer.count, limit + 1 - data.count)
            let count = Darwin.read(file, &buffer, amount)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return .unavailable("读取文件失败，请检查访问权限后重试。")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= limit else { return .tooLarge(limit: limit) }
        if data.contains(where: { $0 == 0 || ($0 < 32 && $0 != 9 && $0 != 10 && $0 != 13 && $0 != 12) }) {
            return .binary
        }
        guard let text = String(data: data, encoding: .utf8) else { return .unsupportedEncoding }
        return .text(text)
    }
}
