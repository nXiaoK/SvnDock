import Foundation

public enum SVNCommandBuilderError: Error, LocalizedError, Equatable, Sendable {
    case executableIsNotAbsoluteFileURL
    case workingCopyIsNotAbsoluteFileURL
    case operationWorkingCopyMismatch
    case invalidArgument(String)
    case pathOutsideWorkingCopy(String)
    case pathsRequired(String)
    case emptyCommitMessage
    case invalidRevision(Int)
    case invalidLogLimit(Int)
    case invalidIgnorePattern(String)

    public var errorDescription: String? {
        switch self {
        case .executableIsNotAbsoluteFileURL:
            return "The SVN executable must be an absolute file URL."
        case .workingCopyIsNotAbsoluteFileURL:
            return "The working copy must be an absolute file URL."
        case .operationWorkingCopyMismatch:
            return "The operation belongs to a different working copy."
        case let .invalidArgument(argument):
            return "An SVN argument is invalid: \(argument)"
        case let .pathOutsideWorkingCopy(path):
            return "The selected path is outside the working copy: \(path)"
        case let .pathsRequired(command):
            return "At least one path is required for svn \(command)."
        case .emptyCommitMessage:
            return "A non-empty commit message is required."
        case let .invalidRevision(revision):
            return "SVN revision must not be negative: \(revision)"
        case let .invalidLogLimit(limit):
            return "SVN log limit must be between 1 and 10,000: \(limit)"
        case let .invalidIgnorePattern(pattern):
            return "An svn:ignore pattern is invalid: \(pattern)"
        }
    }
}

/// Builds an argv array for SVN. It never constructs a shell command string.
///
/// Every selected path is normalized, checked to be within the working copy,
/// and placed after `--` to prevent a filename beginning with `-` from being
/// interpreted as an option.
public struct SVNCommandBuilder: Sendable {
    public let executableURL: URL
    public var nonInteractive: Bool

    public init(executableURL: URL, nonInteractive: Bool = true) throws {
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/") else {
            throw SVNCommandBuilderError.executableIsNotAbsoluteFileURL
        }
        self.executableURL = executableURL.standardizedFileURL
        self.nonInteractive = nonInteractive
    }

    public func makeInvocation(
        for operation: SVNOperation,
        in workingCopy: WorkingCopy
    ) throws -> ProcessInvocation {
        guard operation.workingCopyID == workingCopy.id else {
            throw SVNCommandBuilderError.operationWorkingCopyMismatch
        }
        return try makeInvocation(for: operation.kind, in: workingCopy)
    }

    public func makeInvocation(
        for operation: SVNOperationKind,
        in workingCopy: WorkingCopy
    ) throws -> ProcessInvocation {
        let root = workingCopy.localPath.standardizedFileURL
        guard root.isFileURL, root.path.hasPrefix("/") else {
            throw SVNCommandBuilderError.workingCopyIsNotAbsoluteFileURL
        }

        var arguments: [String]
        var standardInput: Data? = nil

        switch operation {
        case let .status(options):
            // Avoid `--verbose`: it emits every clean versioned node and makes
            // large working copies needlessly expensive. Changed and remote
            // entries still carry the revision information needed by the UI.
            arguments = ["status", "--xml"]
            if options.showRemoteUpdates {
                arguments.append("--show-updates")
            }
            if options.includeIgnored {
                arguments.append("--no-ignore")
            }
            appendCommonOptions(to: &arguments)
            arguments.append("--")
            arguments.append(contentsOf: try safePaths(
                options.paths,
                root: root,
                emptyMeansRoot: true,
                escapePegRevision: true
            ))

        case .info:
            arguments = ["info", "--xml"]
            appendCommonOptions(to: &arguments)
            arguments.append(contentsOf: ["--", "."])

        case let .update(revision):
            arguments = ["update"]
            if let revision {
                if case let .number(value) = revision, value < 0 {
                    throw SVNCommandBuilderError.invalidRevision(value)
                }
                arguments.append(contentsOf: ["--revision", revision.commandLineValue])
            }
            appendCommonOptions(to: &arguments)
            arguments.append(contentsOf: ["--", "."])

        case let .commit(paths, message, keepLocks):
            let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedMessage.isEmpty else {
                throw SVNCommandBuilderError.emptyCommitMessage
            }
            try validate(argument: normalizedMessage)
            // Keep commit text out of argv/process listings. Subversion reads
            // the log message from the process pipe exposed as `/dev/stdin`.
            arguments = ["commit", "--file", "/dev/stdin"]
            standardInput = Data(normalizedMessage.utf8)
            if keepLocks {
                arguments.append("--keep-locks")
            }
            appendCommonOptions(to: &arguments)
            arguments.append("--")
            arguments.append(contentsOf: try safePaths(
                paths,
                root: root,
                emptyMeansRoot: true,
                escapePegRevision: true
            ))

        case let .add(paths, parents):
            arguments = ["add"]
            if parents {
                arguments.append("--parents")
            }
            appendCommonOptions(to: &arguments)
            arguments.append("--")
            arguments.append(contentsOf: try requiredSafePaths(
                paths,
                root: root,
                command: "add",
                escapePegRevision: true
            ))

        case let .revert(paths, depth):
            arguments = ["revert", "--depth", depth.rawValue]
            appendCommonOptions(to: &arguments)
            arguments.append("--")
            arguments.append(contentsOf: try requiredSafePaths(
                paths,
                root: root,
                command: "revert",
                escapePegRevision: true
            ))

        case .cleanup:
            arguments = ["cleanup"]
            appendCommonOptions(to: &arguments)
            arguments.append(contentsOf: ["--", "."])

        case let .diff(paths):
            arguments = ["diff"]
            appendCommonOptions(to: &arguments)
            arguments.append("--")
            // `svn diff` treats a local trailing `@` as part of the filename,
            // unlike commands such as add/commit/revert. Keep local paths raw.
            arguments.append(contentsOf: try safePaths(
                paths,
                root: root,
                emptyMeansRoot: true,
                escapePegRevision: false
            ))

        case let .log(paths, limit):
            guard (1...10_000).contains(limit) else {
                throw SVNCommandBuilderError.invalidLogLimit(limit)
            }
            // For a working-copy path, Subversion otherwise defaults to
            // BASE:1 and hides commits newer than the local checkout.
            arguments = [
                "log", "--xml", "--revision", "HEAD:1",
                "--limit", String(limit)
            ]
            appendCommonOptions(to: &arguments)
            arguments.append("--")
            arguments.append(contentsOf: try safePaths(
                paths,
                root: root,
                emptyMeansRoot: true,
                escapePegRevision: true
            ))

        case let .resolve(paths, accept):
            arguments = ["resolve", "--accept", accept.rawValue]
            appendCommonOptions(to: &arguments)
            arguments.append("--")
            arguments.append(contentsOf: try requiredSafePaths(
                paths,
                root: root,
                command: "resolve",
                escapePegRevision: true
            ))

        case let .properties(paths):
            arguments = ["proplist", "--xml", "--verbose"]
            appendCommonOptions(to: &arguments)
            arguments.append("--")
            arguments.append(contentsOf: try safePaths(
                paths,
                root: root,
                emptyMeansRoot: true,
                escapePegRevision: true
            ))

        case let .setIgnore(path, patterns):
            guard !patterns.isEmpty else {
                throw SVNCommandBuilderError.pathsRequired("propset svn:ignore")
            }
            for pattern in patterns {
                guard !pattern.isEmpty,
                      !pattern.contains("\0"),
                      !pattern.contains("\n"),
                      !pattern.contains("\r") else {
                    throw SVNCommandBuilderError.invalidIgnorePattern(pattern)
                }
            }
            arguments = ["propset", "svn:ignore", "--file", "/dev/stdin"]
            standardInput = Data((patterns.joined(separator: "\n") + "\n").utf8)
            appendCommonOptions(to: &arguments)
            arguments.append("--")
            arguments.append(contentsOf: try requiredSafePaths(
                [path],
                root: root,
                command: "propset svn:ignore",
                escapePegRevision: true
            ))
        }

        return ProcessInvocation(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: root,
            environment: ["LC_ALL": "C", "LANG": "C"],
            standardInput: standardInput
        )
    }

    private func appendCommonOptions(to arguments: inout [String]) {
        if nonInteractive {
            arguments.append("--non-interactive")
        }
    }

    private func requiredSafePaths(
        _ paths: [String],
        root: URL,
        command: String,
        escapePegRevision: Bool
    ) throws -> [String] {
        guard !paths.isEmpty else {
            throw SVNCommandBuilderError.pathsRequired(command)
        }
        return try safePaths(
            paths,
            root: root,
            emptyMeansRoot: false,
            escapePegRevision: escapePegRevision
        )
    }

    private func safePaths(
        _ paths: [String],
        root: URL,
        emptyMeansRoot: Bool,
        escapePegRevision: Bool
    ) throws -> [String] {
        if paths.isEmpty {
            return emptyMeansRoot ? ["."] : []
        }

        return try paths.map { path in
            try validate(argument: path)
            guard !path.isEmpty else {
                throw SVNCommandBuilderError.invalidArgument("path cannot be empty")
            }

            let candidate: URL
            if path.hasPrefix("/") {
                candidate = URL(fileURLWithPath: path).standardizedFileURL
            } else {
                candidate = root.appendingPathComponent(path).standardizedFileURL
            }

            let rootComponents = root.pathComponents
            let candidateComponents = candidate.pathComponents
            guard candidateComponents.count >= rootComponents.count,
                  Array(candidateComponents.prefix(rootComponents.count)) == rootComponents else {
                throw SVNCommandBuilderError.pathOutsideWorkingCopy(path)
            }

            let relativeComponents = candidateComponents.dropFirst(rootComponents.count)
            let relativePath = relativeComponents.isEmpty
                ? "."
                : relativeComponents.joined(separator: "/")
            // In SVN syntax, `@` introduces a peg revision even when it is a
            // literal filename character. A trailing empty peg keeps the full
            // preceding string as the actual path (`name@host` -> `name@host@`).
            return escapePegRevision && relativePath.contains("@")
                ? relativePath + "@"
                : relativePath
        }
    }

    private func validate(argument: String) throws {
        guard !argument.contains("\0") else {
            throw SVNCommandBuilderError.invalidArgument("NUL bytes are not allowed")
        }
    }
}
