import Foundation

public enum AgentQueueStoreError: Error, LocalizedError, Sendable {
    case applicationGroupUnavailable(String)
    case invalidContainerPath
    case unsupportedRegistrySchema(Int)
    case registryTooLarge
    case cannotPrepare(String)
    case cannotReadRegistry
    case cannotWriteDiagnostic

    public var errorDescription: String? {
        switch self {
        case .applicationGroupUnavailable(let identifier):
            return "The App Group container is unavailable: \(identifier)"
        case .invalidContainerPath:
            return "The shared container path must be absolute."
        case .unsupportedRegistrySchema(let version):
            return "Unsupported registered-roots schema version: \(version)"
        case .registryTooLarge:
            return "The registered-roots document exceeds the size limit."
        case .cannotPrepare(let component):
            return "Unable to prepare the Agent directory: \(component)"
        case .cannotReadRegistry:
            return "Unable to read the registered working-copy roots."
        case .cannotWriteDiagnostic:
            return "Unable to persist a safe failure diagnostic."
        }
    }
}

/// Registry and bounded diagnostic persistence owned by the Agent.
///
/// Command ownership deliberately does not live here. All queue transitions
/// are delegated to `SvnDockCore.FinderCommandQueueCoordinator`, which uses
/// tokenized same-volume renames and durable receipts across App/Agent races.
public struct AgentQueueStore: @unchecked Sendable {
    public static let defaultAppGroupIdentifier = "group.com.svndock.shared"
    public static let relativeDirectory = "Library/Application Support/SvnDock"

    private static let maximumRegistrySize = 8 * 1_024 * 1_024
    private static let maximumDiagnosticSize = 256 * 1_024

    public let baseDirectoryURL: URL

    private let fileManager: FileManager

    public init(
        baseDirectoryURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard baseDirectoryURL.isFileURL,
              baseDirectoryURL.path.hasPrefix("/"),
              baseDirectoryURL.standardizedFileURL.path != "/",
              !baseDirectoryURL.path.contains("\0") else {
            throw AgentQueueStoreError.invalidContainerPath
        }
        self.baseDirectoryURL = baseDirectoryURL.standardizedFileURL
        self.fileManager = fileManager
    }

    public init(
        appGroupIdentifier: String = AgentQueueStore.defaultAppGroupIdentifier,
        fileManager: FileManager = .default
    ) throws {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw AgentQueueStoreError.applicationGroupUnavailable(appGroupIdentifier)
        }
        try self.init(
            baseDirectoryURL: container.appendingPathComponent(
                Self.relativeDirectory,
                isDirectory: true
            ),
            fileManager: fileManager
        )
    }

    public var registryURL: URL {
        baseDirectoryURL.appendingPathComponent("registered-roots.json", isDirectory: false)
    }

    public var failureURL: URL {
        baseDirectoryURL.appendingPathComponent("command-failures", isDirectory: true)
    }

    public func prepareDirectories() throws {
        for url in [baseDirectoryURL, failureURL] {
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw AgentQueueStoreError.cannotPrepare(url.lastPathComponent)
            }
        }
    }

    public func loadRegisteredRoots() throws -> [AgentRegisteredRoot] {
        guard fileManager.fileExists(atPath: registryURL.path) else { return [] }
        guard let data = try boundedData(
            from: registryURL,
            maximumSize: Self.maximumRegistrySize
        ) else {
            throw AgentQueueStoreError.registryTooLarge
        }

        let document: AgentRegisteredRootsDocument
        do {
            document = try JSONDecoder().decode(AgentRegisteredRootsDocument.self, from: data)
        } catch {
            throw AgentQueueStoreError.cannotReadRegistry
        }
        guard document.schemaVersion == AgentRegisteredRootsDocument.currentSchemaVersion else {
            throw AgentQueueStoreError.unsupportedRegistrySchema(document.schemaVersion)
        }

        var paths = Set<String>()
        var identifiers = Set<UUID>()
        return document.roots.compactMap { root in
            guard root.enabled, let url = root.standardizedURL else { return nil }
            guard paths.insert(url.path).inserted,
                  identifiers.insert(root.id).inserted else {
                return nil
            }
            return AgentRegisteredRoot(
                id: root.id,
                path: url.path,
                displayName: root.displayName,
                enabled: true
            )
        }
    }

    /// Retry throttling is only used while a command is still in a safe,
    /// pre-execution phase. Executing claims are never returned to pending.
    public func isEligibleForRetry(requestID: UUID, now: Date = Date()) -> Bool {
        guard let diagnostic = existingDiagnostic(for: requestID) else { return true }
        guard diagnostic.retryable else { return false }
        guard let next = diagnostic.nextAttemptAt.flatMap(AgentTimestamp.date(from:)) else {
            return true
        }
        return next <= now
    }

    public func existingDiagnostic(for requestID: UUID) -> AgentFailureDiagnostic? {
        let url = diagnosticURL(for: requestID)
        guard let data = try? boundedData(
            from: url,
            maximumSize: Self.maximumDiagnosticSize
        ) else {
            return nil
        }
        return try? JSONDecoder().decode(AgentFailureDiagnostic.self, from: data)
    }

    public func writeDiagnostic(_ diagnostic: AgentFailureDiagnostic) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(diagnostic)
            guard data.count <= Self.maximumDiagnosticSize else {
                throw AgentQueueStoreError.cannotWriteDiagnostic
            }
            try data.write(to: diagnosticURL(for: diagnostic.requestID), options: [.atomic])
        } catch {
            throw AgentQueueStoreError.cannotWriteDiagnostic
        }
    }

    public func clearDiagnostic(for requestID: UUID) throws {
        let url = diagnosticURL(for: requestID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func diagnosticURL(for requestID: UUID) -> URL {
        failureURL
            .appendingPathComponent(requestID.uuidString.lowercased(), isDirectory: false)
            .appendingPathExtension("failure.json")
    }

    private func boundedData(from url: URL, maximumSize: Int) throws -> Data? {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber,
           size.intValue > maximumSize {
            return nil
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }
}
