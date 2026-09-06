import Foundation
import Darwin

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
/// and passed after `--` or through a targets file to prevent a filename
/// beginning with `-` from being interpreted as an option.
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
        var argumentFiles: [ProcessArgumentFile] = []

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
            if let depth = options.depth {
                arguments.append(contentsOf: ["--depth", depth.rawValue])
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

        case let .infoTargets(paths):
            arguments = ["info", "--xml", "--depth", "empty"]
            appendCommonOptions(to: &arguments)
            appendFileTargets(
                try requiredSafePaths(paths, root: root, command: "info", escapePegRevision: true),
                to: &arguments,
                files: &argumentFiles
            )

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

        case let .commit(paths, message, keepLocks, depth):
            let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedMessage.isEmpty else {
                throw SVNCommandBuilderError.emptyCommitMessage
            }
            try validate(argument: normalizedMessage)
            // Keep commit text out of argv/process listings. Subversion reads
            // the log message from the process pipe exposed as `/dev/stdin`.
            arguments = ["commit", "--file", "/dev/stdin"]
            if let depth {
                arguments.append(contentsOf: ["--depth", depth.rawValue])
            }
            standardInput = Data(normalizedMessage.utf8)
            if keepLocks {
                arguments.append("--no-unlock")
            }
            appendCommonOptions(to: &arguments)
            let targets = try safePaths(
                paths,
                root: root,
                emptyMeansRoot: true,
                escapePegRevision: true
            )
            // A single commit must remain one transaction even for tens of
            // thousands of paths. A targets file avoids both Foundation's
            // argument-count limit and the OS argument-byte limit.
            // SVN splits targets files on CR/LF, so those unusual filenames
            // must remain literal argv entries after the option terminator.
            appendFileTargets(targets, to: &arguments, files: &argumentFiles)

        case let .add(paths, parents, force, depth):
            arguments = ["add"]
            if force {
                arguments.append("--force")
            }
            if parents {
                arguments.append("--parents")
            }
            if let depth {
                arguments.append(contentsOf: ["--depth", depth.rawValue])
            }
            appendCommonOptions(to: &arguments)
            arguments.append("--")
            arguments.append(contentsOf: try requiredSafePaths(
                paths,
                root: root,
                command: "add",
                escapePegRevision: true
            ))

        case let .delete(paths):
            // Only schedule local working-copy deletion. Keeping disk content
            // protects a file recreated after the missing-file preflight.
            arguments = ["delete", "--keep-local"]
            appendCommonOptions(to: &arguments)
            appendFileTargets(
                try requiredSafePaths(paths, root: root, command: "delete", escapePegRevision: true),
                to: &arguments,
                files: &argumentFiles
            )

        case let .revert(paths, depth):
            arguments = ["revert", "--depth", depth.rawValue]
            appendCommonOptions(to: &arguments)
            let targets = try requiredSafePaths(
                paths,
                root: root,
                command: "revert",
                escapePegRevision: true
            )
            if targets.count > 1_000 || targets.reduce(0, { $0 + $1.utf8.count + 1 }) > 64_000 {
                appendFileTargets(targets, to: &arguments, files: &argumentFiles)
            } else {
                arguments.append("--")
                arguments.append(contentsOf: targets)
            }

        case .cleanup:
            arguments = ["cleanup"]
            appendCommonOptions(to: &arguments)
            arguments.append(contentsOf: ["--", "."])

        case let .diff(paths, depth):
            // Side-by-side presentation relies on Subversion's unified diff
            // grammar, regardless of any external diff command in user config.
            arguments = ["diff", "--internal-diff"]
            if let depth {
                arguments.append(contentsOf: ["--depth", depth.rawValue])
            }
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

        case let .revisionLog(repositoryRoot, revision):
            try validateHistoryRevision(revision)
            arguments = ["log", "--xml", "--verbose", "--revision", String(revision), "--limit", "1"]
            appendCommonOptions(to: &arguments)
            arguments.append(contentsOf: ["--", try repositoryTarget(repositoryRoot, revision: revision)])

        case let .revisionSummary(repositoryRoot, revision):
            try validateHistoryRevision(revision)
            arguments = ["diff", "--summarize", "--xml", "--notice-ancestry",
                         "--old", try repositoryTarget(repositoryRoot, revision: revision - 1),
                         "--new", try repositoryTarget(repositoryRoot, revision: revision)]
            appendCommonOptions(to: &arguments)

        case let .revisionDiff(repositoryRoot, revision, change):
            try validateHistoryRevision(revision)
            let path = try SVNRepositoryPath.validate(change.path)
            arguments = ["diff", "--internal-diff", "--depth", "empty"]
            if change.comparesCopySource,
               let sourcePath = change.copyFromPath, let sourceRevision = change.copyFromRevision {
                guard sourceRevision >= 0, sourceRevision < revision else {
                    throw SVNCommandBuilderError.invalidRevision(sourceRevision)
                }
                let source = try SVNRepositoryPath.validate(sourcePath)
                arguments.append(contentsOf: [
                    "--old", try repositoryTarget(repositoryRoot.appendingPathComponent(source), revision: sourceRevision),
                    "--new", try repositoryTarget(repositoryRoot.appendingPathComponent(path), revision: revision)
                ])
                appendCommonOptions(to: &arguments)
            } else {
                // Anchoring both sides at repository roots also supports nodes
                // missing on either side and paths that disappeared after N.
                arguments.append(contentsOf: [
                    "--notice-ancestry", "--show-copies-as-adds",
                    "--old", try repositoryTarget(repositoryRoot, revision: revision - 1),
                    "--new", try repositoryTarget(repositoryRoot, revision: revision)
                ])
                appendCommonOptions(to: &arguments)
                arguments.append(contentsOf: ["--", path])
            }

        case let .log(paths, limit, beforeRevision):
            guard (1...10_000).contains(limit) else {
                throw SVNCommandBuilderError.invalidLogLimit(limit)
            }
            let revisionRange: String
            if let beforeRevision {
                guard beforeRevision >= 0 else {
                    throw SVNCommandBuilderError.invalidRevision(beforeRevision)
                }
                guard beforeRevision > 1 else {
                    throw SVNCommandBuilderError.invalidArgument("log cursor has no earlier revisions")
                }
                // The exclusive cursor is reduced only after validation; even
                // Int.min cannot overflow, and Int.max remains safe.
                revisionRange = "\(beforeRevision - 1):1"
            } else {
                revisionRange = "HEAD:1"
            }
            // For a working-copy path, Subversion otherwise defaults to
            // BASE:1 and hides commits newer than the local checkout.
            // Keep local peg identity for older pages so copies and moves keep
            // following the selected node's ancestry rather than a URL at HEAD.
            arguments = [
                "log", "--xml", "--revision", revisionRange,
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
            arguments = ["resolve", "--accept", accept.rawValue, "--depth", "empty"]
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
            // Keep diagnostics in English without forcing ASCII filenames or
            // commit messages. macOS ships the en_US.UTF-8 locale.
            environment: ["LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8"],
            standardInput: standardInput,
            argumentFiles: argumentFiles
        )
    }

    private func appendCommonOptions(to arguments: inout [String]) {
        if nonInteractive {
            arguments.append("--non-interactive")
        }
    }

    private func validateHistoryRevision(_ revision: Int) throws {
        guard revision > 0 else { throw SVNCommandBuilderError.invalidRevision(revision) }
    }

    private func repositoryTarget(_ url: URL, revision: Int) throws -> String {
        guard let scheme = url.scheme, ["file", "http", "https", "svn", "svn+ssh"].contains(scheme),
              url.query == nil, url.fragment == nil,
              !url.absoluteString.contains("\0") else {
            throw SVNCommandBuilderError.invalidArgument("Invalid SVN repository URL")
        }
        return url.absoluteString + "@" + String(revision)
    }

    private func appendFileTargets(
        _ targets: [String],
        to arguments: inout [String],
        files: inout [ProcessArgumentFile]
    ) {
        var contents = Data()
        var literalTargets: [String] = []
        for target in targets {
            if target.contains("\n") || target.contains("\r") {
                literalTargets.append(target)
            } else {
                contents.append(contentsOf: [0x2e, 0x2f]) // ./
                contents.append(contentsOf: target.utf8)
                contents.append(0x0a)
            }
        }
        if !contents.isEmpty {
            arguments.append("--targets")
            files.append(ProcessArgumentFile(
                argumentIndex: arguments.count,
                contents: contents
            ))
            arguments.append("") // Replaced with a private file path by ProcessRunner.
        }
        arguments.append("--")
        arguments.append(contentsOf: literalTargets)
    }

    /// Returns working-copy-relative paths, accepting the root's physical
    /// spelling too (for example /tmp and /private/tmp), without peg escaping.
    public func normalizedLocalPaths(
        _ paths: [String], in workingCopy: WorkingCopy, command: String = "revert"
    ) throws -> [String] {
        try requiredSafePaths(
            paths,
            root: workingCopy.localPath.standardizedFileURL,
            command: command,
            escapePegRevision: false
        )
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

        let rootComponents = root.pathComponents
        // Foundation sometimes simplifies /private/tmp to /tmp only when the
        // complete path exists. Retain the same root's physical spelling too,
        // so deleting a selected file cannot suddenly make it appear outside
        // the working copy. Resolve the root once, never every selected file.
        let physicalRootComponents: [String]? = root.path.withCString { path in
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return ["/"] + String(cString: resolved).split(separator: "/").map(String.init)
        }
        return try paths.map { path in
            // Foundation's URL normalization creates autoreleased objects.
            // Release them per path instead of retaining tens of thousands
            // of temporary objects until the caller's outer pool drains.
            try autoreleasepool {
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

                let candidateComponents = candidate.pathComponents
                let rootComponentCount: Int
                if candidateComponents.starts(with: rootComponents) {
                    rootComponentCount = rootComponents.count
                } else if let physicalRootComponents, candidateComponents.starts(with: physicalRootComponents) {
                    rootComponentCount = physicalRootComponents.count
                } else {
                    throw SVNCommandBuilderError.pathOutsideWorkingCopy(path)
                }

                let relativeComponents = candidateComponents.dropFirst(rootComponentCount)
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
    }

    private func validate(argument: String) throws {
        guard !argument.contains("\0") else {
            throw SVNCommandBuilderError.invalidArgument("NUL bytes are not allowed")
        }
    }
}
