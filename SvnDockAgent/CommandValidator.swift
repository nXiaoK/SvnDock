import Foundation
import SvnDockCore

public enum AgentCommandValidationError: Error, Sendable {
    case malformedRequest
    case requestTooLarge
    case identifierMismatch
    case unsupportedSchema
    case invalidSource
    case invalidCreationDate
    case invalidRoot
    case unregisteredRoot
    case workingCopyUnavailable
    case tooManyPaths
    case invalidPath
    case pathOutsideWorkingCopy
    case symlinkEscapesWorkingCopy
    case duplicatePath
}

public struct AgentCommandValidator: Sendable {
    public static let maximumSelectedPathCount = 4_096

    public init() {}

    public func validate(
        _ request: FinderCommand,
        registeredRoots: [AgentRegisteredRoot],
        fileManager: FileManager = .default
    ) throws -> ValidatedFinderCommand {
        guard request.schemaVersion == FinderSharedSchema.currentVersion else {
            throw AgentCommandValidationError.unsupportedSchema
        }
        guard request.source == "finder-extension" else {
            throw AgentCommandValidationError.invalidSource
        }
        guard request.workingCopyRoot.hasPrefix("/"),
              !request.workingCopyRoot.contains("\0") else {
            throw AgentCommandValidationError.invalidRoot
        }

        let requestedRoot = URL(
            fileURLWithPath: request.workingCopyRoot,
            isDirectory: true
        ).standardizedFileURL
        guard let registered = registeredRoots.first(where: {
            $0.enabled && $0.standardizedURL?.path == requestedRoot.path
        }) else {
            throw AgentCommandValidationError.unregisteredRoot
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: requestedRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.fileExists(
                atPath: requestedRoot.appendingPathComponent(".svn", isDirectory: true).path
              ) else {
            throw AgentCommandValidationError.workingCopyUnavailable
        }

        guard !request.paths.isEmpty,
              request.paths.count <= Self.maximumSelectedPathCount else {
            throw AgentCommandValidationError.tooManyPaths
        }

        let resolvedRoot = requestedRoot.resolvingSymlinksInPath().standardizedFileURL
        var seen = Set<String>()
        let selectedURLs = try request.paths.map { path -> URL in
            guard path.hasPrefix("/"), !path.contains("\0") else {
                throw AgentCommandValidationError.invalidPath
            }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard Self.contains(url.path, within: requestedRoot.path) else {
                throw AgentCommandValidationError.pathOutsideWorkingCopy
            }

            // A textual child can traverse outside through a symlink. Check the
            // filesystem-resolved path as a second, independent boundary.
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard Self.contains(resolved.path, within: resolvedRoot.path) else {
                throw AgentCommandValidationError.symlinkEscapesWorkingCopy
            }
            guard seen.insert(url.path).inserted else {
                throw AgentCommandValidationError.duplicatePath
            }
            return url
        }

        return ValidatedFinderCommand(
            request: request,
            registeredRoot: registered,
            workingCopyURL: requestedRoot,
            selectedURLs: selectedURLs
        )
    }

    private static func contains(_ candidate: String, within root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
