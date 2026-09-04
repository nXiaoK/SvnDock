import Foundation

public struct SVNExecutableNotFoundError: Error, LocalizedError, Sendable, Equatable {
    public let attemptedPaths: [String]

    public init(attemptedPaths: [String]) {
        self.attemptedPaths = attemptedPaths
    }

    public var errorDescription: String? {
        let paths = attemptedPaths.joined(separator: ", ")
        return "Unable to find an executable SVN client. Checked: \(paths)"
    }
}

/// Locates an SVN command-line client without invoking a login shell.
///
/// The explicit override is useful for managed installations and tests. Common
/// Apple Silicon, Intel Homebrew and system paths are checked before `PATH`.
public struct SVNExecutableLocator: Sendable {
    public static let defaultCandidatePaths = [
        "/opt/homebrew/bin/svn",
        "/usr/local/bin/svn",
        "/opt/local/bin/svn",
        "/usr/bin/svn"
    ]

    public let candidatePaths: [String]
    public let environmentOverrideKey: String

    public init(
        candidatePaths: [String] = SVNExecutableLocator.defaultCandidatePaths,
        environmentOverrideKey: String = "SVNDOCK_SVN_PATH"
    ) {
        self.candidatePaths = candidatePaths
        self.environmentOverrideKey = environmentOverrideKey
    }

    public func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> URL {
        var paths: [String] = []

        if let override = environment[environmentOverrideKey], !override.isEmpty {
            paths.append(override)
        }

        paths.append(contentsOf: candidatePaths)

        if let pathValue = environment["PATH"] {
            paths.append(contentsOf: pathValue
                .split(separator: ":", omittingEmptySubsequences: true)
                .map { directory in
                    URL(fileURLWithPath: String(directory), isDirectory: true)
                        .appendingPathComponent("svn", isDirectory: false)
                        .path
                })
        }

        var seen = Set<String>()
        let uniquePaths = paths.compactMap { path -> String? in
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            return seen.insert(standardized).inserted ? standardized : nil
        }

        for path in uniquePaths where fileManager.isExecutableFile(atPath: path) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }
            return URL(fileURLWithPath: path, isDirectory: false)
        }

        throw SVNExecutableNotFoundError(attemptedPaths: uniquePaths)
    }
}
