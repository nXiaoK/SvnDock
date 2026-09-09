import Darwin
import Foundation

public enum SVNCheckoutError: Error, LocalizedError, Sendable {
    case invalidRepositoryURL
    case invalidDestination
    case parentDirectoryMissing
    case destinationNotEmpty
    case destinationChanged
    case commandFailed(String)
    case invalidWorkingCopy
    case publishFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidRepositoryURL: "请输入有效的 SVN 仓库地址（http、https、svn、svn+ssh 或 file），不要在地址中包含密码、查询参数或片段。"
        case .invalidDestination: "请选择本地的新目录或空目录，不能使用文件、符号链接或磁盘根目录。"
        case .parentDirectoryMissing: "目标目录的父目录不存在，请先选择或创建父目录。"
        case .destinationNotEmpty: "目标目录不是空目录。为保留已有文件，请选择新目录或空目录。"
        case .destinationChanged: "检出期间目标目录发生变化，未覆盖目标内容，请重新选择路径。"
        case .commandFailed(let message): "SVN 检出失败：\n\(message)\n\n私有仓库请确认本机 SVN 已配置认证和证书信任。"
        case .invalidWorkingCopy: "SVN 返回的检出结果未通过工作副本校验，未添加项目。"
        case .publishFailed(let code): "无法将检出结果保存到目标目录（系统错误 \(code)），未覆盖已有文件。"
        }
    }
}

/// Download into a private sibling, then publish without replacing local data.
/// A failed or cancelled download never leaves a partial target working copy.
public struct SVNCheckout: Sendable {
    private let executableURL: URL
    private let runner: any ProcessRunning

    public init(executableURL: URL, runner: any ProcessRunning = ProcessRunner()) throws {
        _ = try SVNCommandBuilder(executableURL: executableURL)
        self.executableURL = executableURL
        self.runner = runner
    }

    public static func repositoryURL(from address: String) throws -> URL {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.rangeOfCharacter(from: .controlCharacters) == nil,
              let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "svn", "svn+ssh", "file"].contains(scheme),
              components.password == nil, components.query == nil, components.fragment == nil,
              let url = components.url,
              scheme == "file" ? url.path.hasPrefix("/") && (url.host == nil || url.host == "" || url.host == "localhost")
                  : components.host?.isEmpty == false else {
            throw SVNCheckoutError.invalidRepositoryURL
        }
        return url
    }

    public func run(repositoryURL: URL, destinationURL: URL,
                    progress: @escaping @Sendable (SVNProgressSnapshot) -> Void = { _ in }) async throws -> URL {
        let source = try Self.repositoryURL(from: repositoryURL.absoluteString)
        let destination = try Destination(destinationURL)
        try Task.checkCancellation()
        let stage = destination.parent.appendingPathComponent(".svndock-checkout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: stage) } }
        let observer = CheckoutProgress(stage: stage, progress: progress)
        progress(.init())
        // Explicit HEAD peg protects literal @ in repository paths. The local
        // destination is a literal final argument and must not receive a peg.
        let result = try await runner.run(ProcessInvocation(executableURL: executableURL,
            arguments: ["checkout", "--non-interactive", "--ignore-externals", "--", source.absoluteString + "@HEAD", stage.path],
            currentDirectoryURL: destination.parent,
            environment: ["LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8"]), onOutput: { observer.consume($0) })
        observer.finish()
        guard result.succeeded else { throw SVNCheckoutError.commandFailed(result.standardErrorString) }
        try Task.checkCancellation()
        progress(.init(phase: .awaitingServer, processedItemCount: observer.processedCount))
        let builder = try SVNCommandBuilder(executableURL: executableURL)
        let infoResult = try await runner.run(builder.makeInvocation(for: .info, in: WorkingCopy(localPath: stage)))
        guard infoResult.succeeded else { throw SVNCheckoutError.invalidWorkingCopy }
        let info = try SVNXMLParser.parseInfo(infoResult.standardOutput)
        guard info.kind == .directory, info.repositoryUUID != nil, info.url != nil,
              info.workingCopyRootURL?.resolvingSymlinksInPath() == stage.resolvingSymlinksInPath() else {
            throw SVNCheckoutError.invalidWorkingCopy
        }
        try Task.checkCancellation()
        try destination.publish(stage)
        published = true
        return destination.url
    }

    private struct Destination {
        let url: URL
        let parent: URL
        let original: stat?

        init(_ input: URL) throws {
            guard input.isFileURL, input.path.hasPrefix("/"), !input.path.contains("\0"),
                  input.standardizedFileURL.path != "/" else { throw SVNCheckoutError.invalidDestination }
            let standardized = input.standardizedFileURL
            parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw SVNCheckoutError.parentDirectoryMissing
            }
            url = parent.appendingPathComponent(standardized.lastPathComponent, isDirectory: true)
            original = try Self.inspect(url)
        }

        private static func inspect(_ url: URL) throws -> stat? {
            var value = stat()
            if lstat(url.path, &value) != 0 {
                guard errno == ENOENT else { throw SVNCheckoutError.invalidDestination }
                return nil
            }
            guard (value.st_mode & S_IFMT) == S_IFDIR else { throw SVNCheckoutError.invalidDestination }
            guard try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty else {
                throw SVNCheckoutError.destinationNotEmpty
            }
            return value
        }

        func publish(_ stage: URL) throws {
            let current = try Self.inspect(url)
            guard original?.st_dev == current?.st_dev, original?.st_ino == current?.st_ino else {
                throw SVNCheckoutError.destinationChanged
            }
            if let original {
                try FileManager.default.setAttributes([.posixPermissions: Int(original.st_mode & 0o777)], ofItemAtPath: stage.path)
            }
            // rmdir cannot remove a directory that received files after the
            // preflight. RENAME_EXCL also protects a destination created later.
            if original != nil, rmdir(url.path) != 0 { throw SVNCheckoutError.destinationChanged }
            if renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, url.path, UInt32(RENAME_EXCL)) != 0 {
                let code = errno
                if let original { _ = mkdir(url.path, original.st_mode & 0o7777) }
                throw SVNCheckoutError.publishFailed(code)
            }
        }
    }
}

private final class CheckoutProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = SVNProgressParser()
    private let prefix: String
    private let progress: @Sendable (SVNProgressSnapshot) -> Void
    init(stage: URL, progress: @escaping @Sendable (SVNProgressSnapshot) -> Void) {
        prefix = stage.path + "/"
        self.progress = progress
    }
    var processedCount: Int { lock.withLock { parser.snapshot.processedItemCount } }
    func consume(_ chunk: ProcessOutputChunk) {
        lock.withLock { if let value = parser.consume(chunk) { report(value) } }
    }
    func finish() {
        lock.withLock { if let value = parser.finish() { report(value) } }
    }
    private func report(_ value: SVNProgressSnapshot) {
        var value = value
        if let path = value.currentPath, path.hasPrefix(prefix) { value.currentPath = String(path.dropFirst(prefix.count)) }
        progress(value)
    }
}
