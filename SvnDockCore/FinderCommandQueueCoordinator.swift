import Darwin
import Foundation

/// The two processes that may consume Finder commands.
public enum FinderCommandConsumer: String, Codable, Hashable, Sendable {
    case application
    case agent
}

/// Durable phases of an owned command. Only `executing` has an unknown
/// outcome after a process crash.
public enum FinderCommandClaimPhase: String, Codable, Hashable, Sendable {
    case claimed
    case awaitingUser
    case executing
}

public enum FinderCommandReceiptOutcome: String, Codable, Hashable, Sendable {
    case completed
    case cancelled
    case rejected
}

public struct FinderCommandReceipt: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let command: FinderCommand
    public let owner: FinderCommandConsumer
    public let claimToken: UUID
    public let outcome: FinderCommandReceiptOutcome
    public let completedAt: Date

    public init(
        schemaVersion: Int = FinderSharedSchema.currentVersion,
        command: FinderCommand,
        owner: FinderCommandConsumer,
        claimToken: UUID,
        outcome: FinderCommandReceiptOutcome,
        completedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.command = command
        self.owner = owner
        self.claimToken = claimToken
        self.outcome = outcome
        self.completedAt = completedAt
    }
}

/// An opaque capability proving ownership of one command. The random token is
/// part of the processing filename, so a stale owner cannot finish a later
/// claim for the same request identifier.
public struct FinderCommandClaim: Hashable, Sendable {
    public let command: FinderCommand
    public let owner: FinderCommandConsumer
    public let token: UUID
    public let phase: FinderCommandClaimPhase

    fileprivate let fileURL: URL

    fileprivate init(
        command: FinderCommand,
        owner: FinderCommandConsumer,
        token: UUID,
        phase: FinderCommandClaimPhase,
        fileURL: URL
    ) {
        self.command = command
        self.owner = owner
        self.token = token
        self.phase = phase
        self.fileURL = fileURL
    }
}

public enum FinderCommandLocation: Equatable, Sendable {
    case pending
    case applicationInbox
    case processing(owner: FinderCommandConsumer, phase: FinderCommandClaimPhase)
    case completed(FinderCommandReceiptOutcome)
    case uncertain
    case absent
}

public struct FinderCommandRecoverySummary: Equatable, Sendable {
    public var released = 0
    public var completedCleanup = 0
    public var quarantined = 0

    public init(released: Int = 0, completedCleanup: Int = 0, quarantined: Int = 0) {
        self.released = released
        self.completedCleanup = completedCleanup
        self.quarantined = quarantined
    }
}

public enum FinderCommandReleaseDisposition: Equatable, Sendable {
    case released
    case collapsedIdenticalDuplicate
    case quarantinedConflict
}

public enum FinderCommandHandoffDisposition: Equatable, Sendable {
    case handedOff
    case collapsedIdenticalDuplicate
    case quarantinedConflict
}

public enum FinderCommandQueueError: Error, LocalizedError, Sendable {
    case invalidDirectory
    case cannotPrepareDirectory(String)
    case cannotAcquireConsumerLease(FinderCommandConsumer, Int32)
    case consumerLeaseAlreadyHeld(FinderCommandConsumer)
    case invalidConsumerLease
    case invalidCommandFile(String)
    case commandTooLarge
    case commandIdentifierMismatch(expected: UUID, actual: UUID)
    case unsupportedSchemaVersion(Int)
    case staleClaim
    case invalidPhaseTransition(from: FinderCommandClaimPhase, to: FinderCommandClaimPhase)
    case invalidReceiptOutcome(
        phase: FinderCommandClaimPhase,
        outcome: FinderCommandReceiptOutcome
    )
    case destinationAlreadyExists(String)
    case conflictingCommandCopies(UUID)
    case receiptConflict(UUID)
    case filesystemFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDirectory:
            return "The Finder command queue directory must be an absolute file URL."
        case let .cannotPrepareDirectory(name):
            return "Unable to prepare the Finder command directory: \(name)"
        case let .cannotAcquireConsumerLease(owner, code):
            return "Unable to acquire the \(owner.rawValue) queue lease (errno \(code))."
        case let .consumerLeaseAlreadyHeld(owner):
            return "Another \(owner.rawValue) command consumer is already active."
        case .invalidConsumerLease:
            return "The command consumer lease does not belong to this queue."
        case let .invalidCommandFile(name):
            return "Invalid Finder command file: \(name)"
        case .commandTooLarge:
            return "The Finder command exceeds the size limit."
        case let .commandIdentifierMismatch(expected, actual):
            return "Finder command identifier mismatch: expected \(expected), found \(actual)."
        case let .unsupportedSchemaVersion(version):
            return "Unsupported Finder command schema version: \(version)"
        case .staleClaim:
            return "The Finder command claim is stale or no longer owned by this process."
        case let .invalidPhaseTransition(from, to):
            return "Invalid Finder command transition from \(from.rawValue) to \(to.rawValue)."
        case let .invalidReceiptOutcome(phase, outcome):
            return "Invalid \(outcome.rawValue) receipt for a \(phase.rawValue) Finder command."
        case let .destinationAlreadyExists(name):
            return "A Finder command already exists at the destination: \(name)"
        case let .conflictingCommandCopies(id):
            return "Conflicting physical copies exist for Finder command \(id)."
        case let .receiptConflict(id):
            return "A conflicting completion receipt already exists for Finder command \(id)."
        case let .filesystemFailure(action):
            return "The Finder command queue could not \(action)."
        }
    }
}

/// A process-lifetime singleton lease for one consumer. Recovery APIs require
/// this capability, which prevents a newly launched copy from reclaiming files
/// while an older copy can still be executing them.
public final class FinderCommandConsumerLease: @unchecked Sendable {
    public let owner: FinderCommandConsumer

    fileprivate let baseDirectoryPath: String
    private let descriptor: Int32

    fileprivate init(
        owner: FinderCommandConsumer,
        baseDirectoryPath: String,
        descriptor: Int32
    ) {
        self.owner = owner
        self.baseDirectoryPath = baseDirectoryPath
        self.descriptor = descriptor
    }

    deinit {
        _ = svnDockFlock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }
}

/// Cross-process state machine for Finder requests.
///
/// Every ownership change is a same-volume rename. Pending files are immutable;
/// consumers never execute a command until they own a tokenized file under
/// `command-processing/<owner>`. A durable receipt is written before a claim is
/// removed. On recovery, a claimed/awaiting-user item is safe to release, while
/// an executing item is quarantined as an unknown outcome and is never blindly
/// replayed.
public actor FinderCommandQueueCoordinator {
    private static let maximumCommandFileSize = 256 * 1_024

    public nonisolated let directoryURL: URL
    private let fileManager: FileManager

    public init(directoryURL: URL, fileManager: FileManager = .default) throws {
        guard directoryURL.isFileURL, directoryURL.path.hasPrefix("/") else {
            throw FinderCommandQueueError.invalidDirectory
        }
        self.directoryURL = directoryURL.standardizedFileURL
        self.fileManager = fileManager
    }

    public func prepareDirectories() throws {
        try ensureDirectories()
    }

    /// Returns `nil` when another process won the rename or the request has
    /// already reached another durable state.
    public func claimCommand(
        id: UUID,
        as owner: FinderCommandConsumer
    ) throws -> FinderCommandClaim? {
        try ensureDirectories()
        return try withStateLock {

            // A durable receipt is the terminal authority for this immutable
            // request identifier. Never resurrect a duplicate pending file.
            if try loadReceipt(id: id) != nil {
                return nil
            }
            for currentOwner in [FinderCommandConsumer.application, .agent] {
                if try processingPhase(id: id, owner: currentOwner) != nil {
                    return nil
                }
            }
            if try directoryContainsCommand(id: id, directory: uncertainURL) {
                return nil
            }

            // An App-specific copy is authoritative. This also closes the
            // race where the same immutable request was physically written to
            // both directories before either consumer acquired ownership.
            if owner == .agent,
               commandURLs(id: id, in: applicationInboxURL).contains(where: {
                   fileManager.fileExists(atPath: $0.path)
               }) {
                return nil
            }

            let sources: [URL]
            switch owner {
            case .application:
                sources = commandURLs(id: id, in: applicationInboxURL)
                    + commandURLs(id: id, in: pendingURL)
            case .agent:
                sources = commandURLs(id: id, in: pendingURL)
            }

            guard let source = sources.first(where: {
                fileManager.fileExists(atPath: $0.path)
            }) else {
                return nil
            }
            let sourceCommand: FinderCommand
            do {
                try validateRegularCommandFile(source)
                sourceCommand = try decodeCommand(from: source)
                guard sourceCommand.id == id else {
                    throw FinderCommandQueueError.commandIdentifierMismatch(
                        expected: id,
                        actual: sourceCommand.id
                    )
                }
                guard sourceCommand.schemaVersion == FinderSharedSchema.currentVersion else {
                    throw FinderCommandQueueError.unsupportedSchemaVersion(
                        sourceCommand.schemaVersion
                    )
                }
            } catch {
                try? moveRawClaim(source, to: deadLetterURL, owner: owner)
                throw error
            }

            // Identical duplicates are harmless and collapse behind the one
            // processing claim. Different payloads for one immutable UUID are
            // ambiguous, so quarantine every unowned copy before any command
            // can execute.
            if existingCommandMatch(
                for: sourceCommand,
                in: [applicationInboxURL, pendingURL]
            ) == .conflicting {
                try quarantineUnownedCommandCopies(id: id)
                throw FinderCommandQueueError.conflictingCommandCopies(id)
            }

            let token = UUID()
            let destination = processingFileURL(
                id: id,
                token: token,
                phase: .claimed,
                owner: owner
            )

            do {
                try fileManager.moveItem(at: source, to: destination)
            } catch {
                // A missing source normally means the competing consumer won.
                guard fileManager.fileExists(atPath: source.path) else { return nil }
                throw FinderCommandQueueError.filesystemFailure("claim a request")
            }

            do {
                let command = try decodeCommand(from: destination)
                guard command.id == id else {
                    throw FinderCommandQueueError.commandIdentifierMismatch(
                        expected: id,
                        actual: command.id
                    )
                }
                guard command.schemaVersion == FinderSharedSchema.currentVersion else {
                    throw FinderCommandQueueError.unsupportedSchemaVersion(command.schemaVersion)
                }
                guard command == sourceCommand else {
                    throw FinderCommandQueueError.conflictingCommandCopies(id)
                }
                return FinderCommandClaim(
                    command: command,
                    owner: owner,
                    token: token,
                    phase: .claimed,
                    fileURL: destination
                )
            } catch {
                try? moveRawClaim(destination, to: deadLetterURL, owner: owner)
                throw error
            }
        }
    }

    /// Lists candidates without granting ownership. Callers must still claim
    /// each identifier and trust only the command returned by that claim.
    public func availableCommandIDs(
        for owner: FinderCommandConsumer
    ) throws -> [UUID] {
        try ensureDirectories()
        let directories = owner == .application
            ? [applicationInboxURL, pendingURL]
            : [pendingURL]
        var candidates: [(UUID, Date)] = []
        var seen = Set<UUID>()

        for directory in directories {
            let contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey
                ],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
            for url in contents {
                guard url.pathExtension.lowercased() == "json",
                      let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      seen.insert(id).inserted,
                      let values = try? url.resourceValues(forKeys: [
                          .isRegularFileKey,
                          .isSymbolicLinkKey,
                          .contentModificationDateKey
                      ]),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true else {
                    continue
                }
                candidates.append((id, values.contentModificationDate ?? .distantPast))
            }
        }

        return try candidates.filter { id, _ in
            try loadReceipt(id: id) == nil
        }.sorted { lhs, rhs in
            if lhs.1 == rhs.1 { return lhs.0.uuidString < rhs.0.uuidString }
            return lhs.1 < rhs.1
        }.map(\.0)
    }

    public func markAwaitingUser(
        _ claim: FinderCommandClaim
    ) throws -> FinderCommandClaim {
        try transition(claim, to: .awaitingUser)
    }

    public func markExecuting(
        _ claim: FinderCommandClaim
    ) throws -> FinderCommandClaim {
        try transition(claim, to: .executing)
    }

    /// Atomically publishes an Agent-owned request to the App-specific inbox.
    /// The caller should wake the main app only after this method returns.
    @discardableResult
    public func handoffToApplication(
        _ claim: FinderCommandClaim
    ) throws -> FinderCommandHandoffDisposition {
        guard claim.owner == .agent, claim.phase == .claimed else {
            throw FinderCommandQueueError.invalidPhaseTransition(
                from: claim.phase,
                to: .awaitingUser
            )
        }
        try ensureDirectories()
        return try withStateLock { () -> FinderCommandHandoffDisposition in
            try requireCurrent(claim)
            let destination = pendingFileURL(id: claim.command.id, in: applicationInboxURL)
            if existingCommandMatch(
                for: claim.command,
                in: [applicationInboxURL, pendingURL]
            ) == .conflicting {
                try quarantineLocked(claim)
                return .quarantinedConflict
            }
            switch existingCommandMatch(
                for: claim.command,
                in: applicationInboxURL
            ) {
            case .absent:
                break
            case .identical:
                // Another producer published the same immutable request while
                // the Agent owned its queue copy. Keep the App-visible copy
                // and collapse this duplicate claim without executing it.
                do {
                    try fileManager.removeItem(at: claim.fileURL)
                } catch {
                    throw FinderCommandQueueError.filesystemFailure(
                        "collapse an identical handoff"
                    )
                }
                return .collapsedIdenticalDuplicate
            case .conflicting:
                // Persist ambiguity before returning. If the short-lived Agent
                // exits immediately afterward, startup recovery can never put
                // this already-detected conflict back into the executable
                // queue.
                try quarantineLocked(claim)
                return .quarantinedConflict
            }
            do {
                try fileManager.moveItem(at: claim.fileURL, to: destination)
            } catch {
                throw FinderCommandQueueError.filesystemFailure("handoff a request")
            }
            return .handedOff
        }
    }

    /// Finishes a request by writing an atomic durable receipt first, then
    /// removing the owned command file. Recovery can safely finish the latter
    /// cleanup if the process dies between these two steps.
    public func acknowledge(
        _ claim: FinderCommandClaim,
        outcome: FinderCommandReceiptOutcome
    ) throws {
        try ensureDirectories()
        let validOutcome: Bool = switch (claim.phase, outcome) {
        case (.claimed, .cancelled), (.claimed, .rejected),
             (.awaitingUser, .cancelled), (.awaitingUser, .rejected),
             (.executing, .completed), (.executing, .rejected):
            true
        default:
            false
        }
        guard validOutcome else {
            throw FinderCommandQueueError.invalidReceiptOutcome(
                phase: claim.phase,
                outcome: outcome
            )
        }
        try withStateLock {
            try requireCurrent(claim)
            let receipt = FinderCommandReceipt(
                command: claim.command,
                owner: claim.owner,
                claimToken: claim.token,
                outcome: outcome
            )
            let destination = receiptURL(id: claim.command.id)
            if fileManager.fileExists(atPath: destination.path) {
                let existing = try decode(FinderCommandReceipt.self, from: destination)
                guard existing.schemaVersion == FinderSharedSchema.currentVersion,
                      existing.command == claim.command,
                      existing.owner == claim.owner,
                      existing.claimToken == claim.token,
                      existing.outcome == outcome else {
                    throw FinderCommandQueueError.receiptConflict(claim.command.id)
                }
            } else {
                do {
                    try encode(receipt).write(to: destination, options: .atomic)
                } catch {
                    throw FinderCommandQueueError.filesystemFailure("write a completion receipt")
                }
            }

            do {
                try fileManager.removeItem(at: claim.fileURL)
            } catch {
                throw FinderCommandQueueError.filesystemFailure("remove a completed claim")
            }
        }
    }

    /// Confirms the exact terminal write after an ambiguous acknowledgement
    /// error (for example, receipt persistence succeeded but claim deletion
    /// failed). A receipt for the same UUID but another owner, token, command,
    /// or outcome is never accepted as this claim's completion.
    public func hasMatchingReceipt(
        for claim: FinderCommandClaim,
        outcome: FinderCommandReceiptOutcome
    ) throws -> Bool {
        try ensureDirectories()
        return try withStateLock {
            guard let receipt = try loadReceipt(id: claim.command.id) else {
                return false
            }
            return receipt.command == claim.command
                && receipt.owner == claim.owner
                && receipt.claimToken == claim.token
                && receipt.outcome == outcome
        }
    }

    /// Releases a command only when execution has not begun. This is used for
    /// cancellation while waiting for UI or for a transient preflight failure.
    @discardableResult
    public func releaseWithoutExecution(
        _ claim: FinderCommandClaim
    ) throws -> FinderCommandReleaseDisposition {
        guard claim.phase != .executing else {
            throw FinderCommandQueueError.invalidPhaseTransition(
                from: claim.phase,
                to: .claimed
            )
        }
        try ensureDirectories()
        return try withStateLock { () -> FinderCommandReleaseDisposition in
            try requireCurrent(claim)
            let destinationDirectory = claim.owner == .application
                ? applicationInboxURL
                : pendingURL
            let destination = pendingFileURL(id: claim.command.id, in: destinationDirectory)

            if existingCommandMatch(
                for: claim.command,
                in: [applicationInboxURL, pendingURL]
            ) == .conflicting {
                try quarantineLocked(claim)
                return .quarantinedConflict
            }

            // A recovered Agent claim may have crashed during an older
            // handoff implementation. Resolve an App-inbox sibling first so
            // recovery cannot reintroduce a pending copy behind it.
            if claim.owner == .agent {
                switch existingCommandMatch(
                    for: claim.command,
                    in: applicationInboxURL
                ) {
                case .absent:
                    break
                case .identical:
                    do {
                        try fileManager.removeItem(at: claim.fileURL)
                    } catch {
                        throw FinderCommandQueueError.filesystemFailure(
                            "collapse a recovered handoff"
                        )
                    }
                    return .collapsedIdenticalDuplicate
                case .conflicting:
                    try quarantineLocked(claim)
                    return .quarantinedConflict
                }
            }
            switch existingCommandMatch(
                for: claim.command,
                in: destinationDirectory
            ) {
            case .absent:
                break
            case .identical:
                do {
                    try fileManager.removeItem(at: claim.fileURL)
                } catch {
                    throw FinderCommandQueueError.filesystemFailure(
                        "collapse an identical released request"
                    )
                }
                return .collapsedIdenticalDuplicate
            case .conflicting:
                try quarantineLocked(claim)
                return .quarantinedConflict
            }
            do {
                try fileManager.moveItem(at: claim.fileURL, to: destination)
            } catch {
                throw FinderCommandQueueError.filesystemFailure("release an unexecuted claim")
            }
            return .released
        }
    }

    /// Moves a claim to the uncertain area. No consumer enumerates this
    /// directory, so commands with an unknown outcome can never hot-loop.
    public func quarantine(_ claim: FinderCommandClaim) throws {
        try ensureDirectories()
        try withStateLock {
            try quarantineLocked(claim)
        }
    }

    private func quarantineLocked(_ claim: FinderCommandClaim) throws {
        try requireCurrent(claim)
        let destination = quarantineFileURL(for: claim)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw FinderCommandQueueError.destinationAlreadyExists(destination.lastPathComponent)
        }
        do {
            try fileManager.moveItem(at: claim.fileURL, to: destination)
        } catch {
            throw FinderCommandQueueError.filesystemFailure("quarantine an uncertain request")
        }
    }

    public func location(of id: UUID) throws -> FinderCommandLocation {
        try ensureDirectories()
        return try withStateLock {
            if let receipt = try loadReceipt(id: id) {
                return .completed(receipt.outcome)
            }
            for owner in [FinderCommandConsumer.application, .agent] {
                if let phase = try processingPhase(id: id, owner: owner) {
                    return .processing(owner: owner, phase: phase)
                }
            }
            if try directoryContainsCommand(id: id, directory: uncertainURL) {
                return .uncertain
            }
            if commandURLs(id: id, in: applicationInboxURL).contains(where: {
                fileManager.fileExists(atPath: $0.path)
            }) {
                return .applicationInbox
            }
            if commandURLs(id: id, in: pendingURL).contains(where: {
                fileManager.fileExists(atPath: $0.path)
            }) {
                return .pending
            }
            return .absent
        }
    }

    /// Acquires a nonblocking process-lifetime owner lease. `nil` means a live
    /// instance already owns the consumer role.
    public func acquireConsumerLease(
        for owner: FinderCommandConsumer
    ) throws -> FinderCommandConsumerLease? {
        try ensureDirectories()
        let url = consumerLeaseURL.appendingPathComponent(
            owner.rawValue + ".lock",
            isDirectory: false
        )
        let descriptor = open(
            url.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw FinderCommandQueueError.cannotAcquireConsumerLease(owner, errno)
        }
        guard isSafePrivateLockFile(descriptor), fchmod(descriptor, 0o600) == 0 else {
            let code = errno
            _ = close(descriptor)
            throw FinderCommandQueueError.cannotAcquireConsumerLease(owner, code)
        }
        while svnDockFlock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            _ = close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN { return nil }
            throw FinderCommandQueueError.cannotAcquireConsumerLease(owner, code)
        }
        return FinderCommandConsumerLease(
            owner: owner,
            baseDirectoryPath: directoryURL.path,
            descriptor: descriptor
        )
    }

    /// Recovers this owner's files only after proving no older instance is
    /// alive. Pre-execution phases are released; executing phases are moved to
    /// the uncertain area unless a matching durable receipt already exists.
    public func recoverOrphanedClaims(
        for owner: FinderCommandConsumer,
        lease: FinderCommandConsumerLease
    ) throws -> FinderCommandRecoverySummary {
        guard lease.owner == owner,
              lease.baseDirectoryPath == directoryURL.path else {
            throw FinderCommandQueueError.invalidConsumerLease
        }
        try ensureDirectories()

        var summary = FinderCommandRecoverySummary()
        let directory = processingDirectory(for: owner)
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )

        for url in contents {
            guard let components = claimFileComponents(url),
                  let values = try? url.resourceValues(forKeys: [
                      .isRegularFileKey,
                      .isSymbolicLinkKey
                  ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                continue
            }

            let command: FinderCommand
            do {
                command = try decodeCommand(from: url)
                guard command.id == components.id else {
                    throw FinderCommandQueueError.commandIdentifierMismatch(
                        expected: components.id,
                        actual: command.id
                    )
                }
            } catch {
                try? moveRawClaim(url, to: deadLetterURL, owner: owner)
                summary.quarantined += 1
                continue
            }

            if let receipt = try loadReceipt(id: components.id) {
                guard receipt.command == command,
                      receipt.owner == owner,
                      receipt.claimToken == components.token else {
                    let claim = FinderCommandClaim(
                        command: command,
                        owner: owner,
                        token: components.token,
                        phase: components.phase,
                        fileURL: url
                    )
                    if (try? quarantine(claim)) != nil {
                        summary.quarantined += 1
                    }
                    continue
                }
                do {
                    try fileManager.removeItem(at: url)
                    summary.completedCleanup += 1
                } catch {
                    // Keep the matching claim for the next recovery pass.
                }
                continue
            }

            let claim = FinderCommandClaim(
                command: command,
                owner: owner,
                token: components.token,
                phase: components.phase,
                fileURL: url
            )
            switch components.phase {
            case .claimed, .awaitingUser:
                do {
                    switch try releaseWithoutExecution(claim) {
                    case .released, .collapsedIdenticalDuplicate:
                        summary.released += 1
                    case .quarantinedConflict:
                        summary.quarantined += 1
                    }
                } catch {
                    if (try? quarantine(claim)) != nil {
                        summary.quarantined += 1
                    }
                }
            case .executing:
                do {
                    try quarantine(claim)
                    summary.quarantined += 1
                } catch {
                    // Leave the owner-specific file in place rather than risk
                    // replay when quarantine persistence itself fails.
                }
            }
        }
        return summary
    }

    private var pendingURL: URL {
        directoryURL.appendingPathComponent(
            FinderSharedSchema.commandQueueDirectoryName,
            isDirectory: true
        )
    }

    private var applicationInboxURL: URL {
        directoryURL.appendingPathComponent("command-app-inbox", isDirectory: true)
    }

    private var processingRootURL: URL {
        directoryURL.appendingPathComponent("command-processing", isDirectory: true)
    }

    private var receiptsURL: URL {
        directoryURL.appendingPathComponent("command-receipts", isDirectory: true)
    }

    private var uncertainURL: URL {
        directoryURL.appendingPathComponent("command-uncertain", isDirectory: true)
    }

    private var deadLetterURL: URL {
        directoryURL.appendingPathComponent("command-dead-letter", isDirectory: true)
    }

    private var consumerLeaseURL: URL {
        directoryURL.appendingPathComponent("consumer-locks", isDirectory: true)
    }

    private var stateLockURL: URL {
        directoryURL.appendingPathComponent("command-state.lock", isDirectory: false)
    }

    private func processingDirectory(for owner: FinderCommandConsumer) -> URL {
        processingRootURL.appendingPathComponent(owner.rawValue, isDirectory: true)
    }

    private func ensureDirectories() throws {
        let directories = [
            directoryURL,
            pendingURL,
            applicationInboxURL,
            processingRootURL,
            processingDirectory(for: .application),
            processingDirectory(for: .agent),
            receiptsURL,
            uncertainURL,
            deadLetterURL,
            consumerLeaseURL
        ]
        for url in directories {
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw FinderCommandQueueError.cannotPrepareDirectory(url.lastPathComponent)
            }
        }
    }

    private func commandURLs(id: UUID, in directory: URL) -> [URL] {
        [id.uuidString.lowercased(), id.uuidString.uppercased()].map {
            directory.appendingPathComponent($0, isDirectory: false)
                .appendingPathExtension("json")
        }
    }

    private func pendingFileURL(id: UUID, in directory: URL) -> URL {
        directory
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: false)
            .appendingPathExtension("json")
    }

    private func processingFileURL(
        id: UUID,
        token: UUID,
        phase: FinderCommandClaimPhase,
        owner: FinderCommandConsumer
    ) -> URL {
        processingDirectory(for: owner)
            .appendingPathComponent(
                "\(id.uuidString.lowercased()).\(token.uuidString.lowercased()).\(phase.rawValue)",
                isDirectory: false
            )
            .appendingPathExtension("json")
    }

    private func receiptURL(id: UUID) -> URL {
        receiptsURL
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: false)
            .appendingPathExtension("json")
    }

    private func quarantineFileURL(for claim: FinderCommandClaim) -> URL {
        uncertainURL
            .appendingPathComponent(
                "\(claim.command.id.uuidString.lowercased()).\(claim.token.uuidString.lowercased()).\(claim.owner.rawValue).\(claim.phase.rawValue)",
                isDirectory: false
            )
            .appendingPathExtension("json")
    }

    private func transition(
        _ claim: FinderCommandClaim,
        to phase: FinderCommandClaimPhase
    ) throws -> FinderCommandClaim {
        let valid: Bool = switch (claim.phase, phase) {
        case (.claimed, .awaitingUser), (.claimed, .executing), (.awaitingUser, .executing):
            true
        default:
            false
        }
        guard valid else {
            throw FinderCommandQueueError.invalidPhaseTransition(from: claim.phase, to: phase)
        }
        try ensureDirectories()
        return try withStateLock {
            try requireCurrent(claim)
            let destination = processingFileURL(
                id: claim.command.id,
                token: claim.token,
                phase: phase,
                owner: claim.owner
            )
            do {
                try fileManager.moveItem(at: claim.fileURL, to: destination)
            } catch {
                throw FinderCommandQueueError.filesystemFailure("advance a request phase")
            }
            return FinderCommandClaim(
                command: claim.command,
                owner: claim.owner,
                token: claim.token,
                phase: phase,
                fileURL: destination
            )
        }
    }

    private func requireCurrent(_ claim: FinderCommandClaim) throws {
        let expected = processingFileURL(
            id: claim.command.id,
            token: claim.token,
            phase: claim.phase,
            owner: claim.owner
        )
        guard expected.standardizedFileURL.path == claim.fileURL.standardizedFileURL.path,
              fileManager.fileExists(atPath: expected.path) else {
            throw FinderCommandQueueError.staleClaim
        }
        try validateRegularCommandFile(expected)
    }

    private func withStateLock<Result>(_ operation: () throws -> Result) throws -> Result {
        let descriptor = open(
            stateLockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw FinderCommandQueueError.filesystemFailure("open the queue state lock")
        }
        defer { _ = close(descriptor) }

        guard isSafePrivateLockFile(descriptor), fchmod(descriptor, 0o600) == 0 else {
            throw FinderCommandQueueError.filesystemFailure("validate the queue state lock")
        }
        while svnDockFlock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw FinderCommandQueueError.filesystemFailure("acquire the queue state lock")
        }
        defer { _ = svnDockFlock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func isSafePrivateLockFile(_ descriptor: Int32) -> Bool {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { return false }
        return value.st_uid == geteuid()
            && value.st_nlink == 1
            && (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    }

    private func validateRegularCommandFile(_ url: URL) throws {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        } catch {
            throw FinderCommandQueueError.invalidCommandFile(url.lastPathComponent)
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw FinderCommandQueueError.invalidCommandFile(url.lastPathComponent)
        }
    }

    private func decodeCommand(from url: URL) throws -> FinderCommand {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber,
           size.intValue > Self.maximumCommandFileSize {
            throw FinderCommandQueueError.commandTooLarge
        }
        return try decode(FinderCommand.self, from: url)
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.timestamp(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = Self.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO-8601 date"
                )
            }
            return date
        }
        return try decoder.decode(type, from: Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    private func loadReceipt(id: UUID) throws -> FinderCommandReceipt? {
        let url = receiptURL(id: id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        try validateRegularCommandFile(url)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber,
           size.intValue > Self.maximumCommandFileSize * 2 {
            throw FinderCommandQueueError.commandTooLarge
        }
        let receipt = try decode(FinderCommandReceipt.self, from: url)
        guard receipt.schemaVersion == FinderSharedSchema.currentVersion,
              receipt.command.id == id else {
            throw FinderCommandQueueError.receiptConflict(id)
        }
        return receipt
    }

    private func processingPhase(
        id: UUID,
        owner: FinderCommandConsumer
    ) throws -> FinderCommandClaimPhase? {
        let contents = try fileManager.contentsOfDirectory(
            at: processingDirectory(for: owner),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        return contents.compactMap(claimFileComponents).first(where: { $0.id == id })?.phase
    }

    private func directoryContainsCommand(id: UUID, directory: URL) throws -> Bool {
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        let prefix = id.uuidString.lowercased() + "."
        return contents.contains {
            $0.lastPathComponent.lowercased().hasPrefix(prefix)
        }
    }

    private enum ExistingCommandMatch {
        case absent
        case identical
        case conflicting
    }

    /// Compares every physical destination spelling. A single malformed or
    /// conflicting sibling makes the state ambiguous and therefore fail
    /// closed; only a set made entirely of byte-decoded equivalent commands
    /// may be collapsed.
    private func existingCommandMatch(
        for command: FinderCommand,
        in directory: URL
    ) -> ExistingCommandMatch {
        existingCommandMatch(for: command, in: [directory])
    }

    private func existingCommandMatch(
        for command: FinderCommand,
        in directories: [URL]
    ) -> ExistingCommandMatch {
        let existingURLs = directories.flatMap {
            commandURLs(id: command.id, in: $0)
        }.filter {
            fileManager.fileExists(atPath: $0.path)
        }
        guard !existingURLs.isEmpty else { return .absent }

        for url in existingURLs {
            do {
                try validateRegularCommandFile(url)
                let existing = try decodeCommand(from: url)
                guard existing.schemaVersion == FinderSharedSchema.currentVersion,
                      existing.id == command.id,
                      existing == command else {
                    return .conflicting
                }
            } catch {
                return .conflicting
            }
        }
        return .identical
    }

    private func quarantineUnownedCommandCopies(id: UUID) throws {
        for directory in [applicationInboxURL, pendingURL] {
            for source in commandURLs(id: id, in: directory) {
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let destination = uncertainURL.appendingPathComponent(
                    "\(id.uuidString.lowercased()).\(UUID().uuidString.lowercased()).unowned.conflict.json",
                    isDirectory: false
                )
                do {
                    try fileManager.moveItem(at: source, to: destination)
                } catch {
                    // A case-insensitive spelling may refer to a file moved by
                    // the previous loop iteration. Any other remaining source
                    // is still protected by the uncertain copy now present.
                    guard fileManager.fileExists(atPath: source.path) else { continue }
                    throw FinderCommandQueueError.filesystemFailure(
                        "quarantine conflicting command copies"
                    )
                }
            }
        }
    }

    private func claimFileComponents(
        _ url: URL
    ) -> (id: UUID, token: UUID, phase: FinderCommandClaimPhase)? {
        guard url.pathExtension.lowercased() == "json" else { return nil }
        let components = url.deletingPathExtension().lastPathComponent.split(separator: ".")
        guard components.count == 3,
              let id = UUID(uuidString: String(components[0])),
              let token = UUID(uuidString: String(components[1])),
              let phase = FinderCommandClaimPhase(rawValue: String(components[2])) else {
            return nil
        }
        return (id, token, phase)
    }

    private func moveRawClaim(
        _ source: URL,
        to directory: URL,
        owner: FinderCommandConsumer
    ) throws {
        let destination = directory.appendingPathComponent(
            "\(owner.rawValue).\(UUID().uuidString.lowercased()).\(source.lastPathComponent)",
            isDirectory: false
        )
        try fileManager.moveItem(at: source, to: destination)
    }

    private static func timestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: value)
    }
}
