import Foundation
import SvnDockCore

public protocol AgentSafeDiagnosticError: Error, Sendable {
    var agentFailureCategory: AgentFailureCategory { get }
    var agentSafeSummary: String { get }
    var agentRetryable: Bool { get }
}

public protocol FinderCommandExecuting: Sendable {
    func execute(_ command: ValidatedFinderCommand) async throws
}

public struct UnconfiguredFinderCommandExecutor: FinderCommandExecuting {
    public init() {}

    public func execute(_ command: ValidatedFinderCommand) async throws {
        throw AgentExecutionError.coreAdapterUnavailable
    }
}

public enum AgentExecutionError: AgentSafeDiagnosticError {
    case coreAdapterUnavailable
    case requiresMainApplication(FinderCommandKind)
    case svnFailed(exitStatus: Int32)

    public var agentFailureCategory: AgentFailureCategory {
        switch self {
        case .requiresMainApplication:
            return .requiresMainApplication
        case .coreAdapterUnavailable:
            return .internalFailure
        case .svnFailed:
            return .executionFailed
        }
    }

    public var agentSafeSummary: String {
        switch self {
        case .coreAdapterUnavailable:
            return "The SvnDockCore executor is not linked into this Agent build."
        case .requiresMainApplication:
            return "This command requires confirmation or presentation by the main application."
        case .svnFailed(let exitStatus):
            return "The SVN operation failed with exit status \(exitStatus)."
        }
    }

    /// Once execution begins, an SVN failure may still have changed the
    /// working copy. The queue processor therefore quarantines it instead of
    /// treating it as a retryable command.
    public var agentRetryable: Bool { false }
}

private enum AgentRequestLifecycleError: AgentSafeDiagnosticError {
    case expired
    case futureDated
    case handoffFailed

    var agentFailureCategory: AgentFailureCategory {
        switch self {
        case .expired, .futureDated:
            return .invalidRequest
        case .handoffFailed:
            return .requiresMainApplication
        }
    }

    var agentSafeSummary: String {
        switch self {
        case .expired:
            return "The Finder request expired before the Agent could process it."
        case .futureDated:
            return "The Finder request has an invalid future creation date."
        case .handoffFailed:
            return "The request could not be handed to the main application safely."
        }
    }

    var agentRetryable: Bool { false }
}

/// Consumes Finder requests through the shared Core state machine.
///
/// A request is either handed to the App while still `claimed`, explicitly
/// rejected, or advanced to `executing`. An executing request is never moved
/// back to pending because SVN may already have produced side effects.
public struct FinderCommandQueueProcessor: Sendable {
    public static let maximumRequestAge: TimeInterval = 5 * 60
    public static let maximumFutureClockSkew: TimeInterval = 60

    private static let handoffNotification = Notification.Name(
        "com.svndock.command-handoff"
    )

    private enum HandoffDisposition: Sendable {
        case handedOff
        case quarantined
        case failed
    }

    private let store: AgentQueueStore
    private let coordinator: FinderCommandQueueCoordinator
    /// Strongly retained for the complete processor lifetime. Releasing this
    /// capability would allow another Agent to recover our live claims.
    private let consumerLease: FinderCommandConsumerLease
    private let validator: AgentCommandValidator
    private let executor: any FinderCommandExecuting

    public init(
        store: AgentQueueStore,
        coordinator: FinderCommandQueueCoordinator,
        consumerLease: FinderCommandConsumerLease,
        validator: AgentCommandValidator = AgentCommandValidator(),
        executor: any FinderCommandExecuting
    ) throws {
        guard consumerLease.owner == .agent,
              coordinator.directoryURL == store.baseDirectoryURL else {
            throw FinderCommandQueueError.invalidConsumerLease
        }
        self.store = store
        self.coordinator = coordinator
        self.consumerLease = consumerLease
        self.validator = validator
        self.executor = executor
    }

    /// Executes one scan. Claims are grouped only after validation so commands
    /// for one registered working copy stay ordered while unrelated roots may
    /// make progress concurrently.
    public func processAvailableCommands(now: Date = Date()) async -> QueueProcessingSummary {
        // Reading the owner makes the lifetime dependency explicit to both
        // readers and the optimizer; the stored lease remains alive throughout.
        _ = consumerLease.owner

        let ids: [UUID]
        do {
            ids = try await coordinator.availableCommandIDs(for: .agent)
        } catch {
            return QueueProcessingSummary(failed: 1)
        }

        var grouped: [UUID: [FinderCommandClaim]] = [:]
        var initial = QueueProcessingSummary()

        for id in ids {
            guard store.isEligibleForRetry(requestID: id, now: now) else {
                initial.skipped += 1
                continue
            }

            let claim: FinderCommandClaim
            do {
                guard let value = try await coordinator.claimCommand(id: id, as: .agent) else {
                    initial.skipped += 1
                    continue
                }
                claim = value
            } catch {
                initial.failed += 1
                continue
            }

            if let lifecycleError = Self.lifecycleError(for: claim.command, now: now) {
                if await reject(claim, because: lifecycleError, now: now) {
                    initial.rejected += 1
                } else {
                    initial.failed += 1
                }
                continue
            }

            if Self.requiresMainApplication(claim.command) {
                switch await handoffToApplication(claim, now: now) {
                case .handedOff:
                    initial.handedOff += 1
                case .quarantined:
                    initial.quarantined += 1
                    initial.failed += 1
                case .failed:
                    initial.failed += 1
                }
                continue
            }

            do {
                let roots = try store.loadRegisteredRoots()
                let command = try validator.validate(
                    claim.command,
                    registeredRoots: roots
                )
                // Only the root ID is needed for grouping. Selected URL
                // arrays are validated again at execution time, so retaining
                // every preflight result would duplicate the whole backlog.
                grouped[command.registeredRoot.id, default: []].append(claim)
            } catch let error as AgentQueueStoreError {
                recordFailure(
                    requestID: id,
                    error: error,
                    now: now,
                    forcedCategory: .registryUnavailable,
                    forcedRetryable: true
                )
                if await releaseBeforeExecution(claim) {
                    initial.failed += 1
                } else {
                    initial.quarantined += 1
                    initial.failed += 1
                }
            } catch {
                if await reject(
                    claim,
                    because: error,
                    now: now,
                    forcedCategory: .invalidRequest
                ) {
                    initial.rejected += 1
                } else {
                    initial.failed += 1
                }
            }
        }

        return await withTaskGroup(of: QueueProcessingSummary.self) { group in
            for commands in grouped.values {
                group.addTask {
                    await processBackgroundCommands(commands)
                }
            }

            var result = initial
            for await partial in group {
                result = result + partial
            }
            return result
        }
    }

    private func processBackgroundCommands(
        _ commands: [FinderCommandClaim]
    ) async -> QueueProcessingSummary {
        var summary = QueueProcessingSummary()

        for claim in commands {
            let requestID = claim.command.id

            if Task.isCancelled {
                if await releaseBeforeExecution(claim) {
                    summary.skipped += 1
                } else {
                    summary.quarantined += 1
                    summary.failed += 1
                }
                continue
            }

            let executionTime = Date()
            if let lifecycleError = Self.lifecycleError(
                for: claim.command,
                now: executionTime
            ) {
                if await reject(
                    claim,
                    because: lifecycleError,
                    now: executionTime
                ) {
                    summary.rejected += 1
                } else {
                    summary.failed += 1
                }
                continue
            }

            let currentCommand: ValidatedFinderCommand
            do {
                // Registry membership and symlink boundaries are re-evaluated
                // immediately before changing the working copy.
                currentCommand = try validator.validate(
                    claim.command,
                    registeredRoots: store.loadRegisteredRoots()
                )
            } catch let error as AgentQueueStoreError {
                recordFailure(
                    requestID: requestID,
                    error: error,
                    now: Date(),
                    forcedCategory: .registryUnavailable,
                    forcedRetryable: true
                )
                if await releaseBeforeExecution(claim) {
                    summary.failed += 1
                } else {
                    summary.quarantined += 1
                    summary.failed += 1
                }
                continue
            } catch {
                if await reject(
                    claim,
                    because: error,
                    now: Date(),
                    forcedCategory: .invalidRequest
                ) {
                    summary.rejected += 1
                } else {
                    summary.failed += 1
                }
                continue
            }

            let executing: FinderCommandClaim
            do {
                executing = try await coordinator.markExecuting(claim)
            } catch {
                recordFailure(requestID: requestID, error: error, now: Date())
                if await quarantine(claim) {
                    summary.quarantined += 1
                }
                summary.failed += 1
                continue
            }

            do {
                try await executor.execute(currentCommand)
            } catch {
                recordFailure(
                    requestID: requestID,
                    error: error,
                    now: Date(),
                    forcedRetryable: false
                )
                if await quarantine(executing) {
                    summary.quarantined += 1
                }
                summary.failed += 1
                continue
            }

            do {
                try await coordinator.acknowledge(executing, outcome: .completed)
                try? store.clearDiagnostic(for: requestID)
                summary.completed += 1
            } catch {
                // The receipt is persisted before claim cleanup. If it exists,
                // recovery can safely finish cleanup and this mutation is done.
                let receiptMatches = try? await coordinator.hasMatchingReceipt(
                    for: executing,
                    outcome: .completed
                )
                if receiptMatches == true {
                    try? store.clearDiagnostic(for: requestID)
                    summary.completed += 1
                } else {
                    recordFailure(
                        requestID: requestID,
                        error: error,
                        now: Date(),
                        forcedRetryable: false
                    )
                    if await quarantine(executing) {
                        summary.quarantined += 1
                    }
                    summary.failed += 1
                }
            }
        }

        return summary
    }

    private func handoffToApplication(
        _ claim: FinderCommandClaim,
        now: Date
    ) async -> HandoffDisposition {
        do {
            let disposition = try await coordinator.handoffToApplication(claim)
            if disposition == .quarantinedConflict {
                recordFailure(
                    requestID: claim.command.id,
                    error: AgentRequestLifecycleError.handoffFailed,
                    now: now,
                    forcedRetryable: false
                )
                return .quarantined
            }
            try? store.clearDiagnostic(for: claim.command.id)
            Self.postHandoffNotification()
            return .handedOff
        } catch {
            recordFailure(
                requestID: claim.command.id,
                error: AgentRequestLifecycleError.handoffFailed,
                now: now,
                forcedRetryable: false
            )
            // A UI-bound request must never fall back into the generic Agent
            // queue. Keep an unsuccessful handoff out of the hot path.
            return await quarantine(claim) ? .quarantined : .failed
        }
    }

    private func reject(
        _ claim: FinderCommandClaim,
        because error: Error,
        now: Date,
        forcedCategory: AgentFailureCategory? = nil
    ) async -> Bool {
        recordFailure(
            requestID: claim.command.id,
            error: error,
            now: now,
            forcedCategory: forcedCategory,
            forcedRetryable: false
        )
        do {
            try await coordinator.acknowledge(claim, outcome: .rejected)
            return true
        } catch {
            _ = await quarantine(claim)
            return false
        }
    }

    private func releaseBeforeExecution(_ claim: FinderCommandClaim) async -> Bool {
        do {
            let disposition = try await coordinator.releaseWithoutExecution(claim)
            return disposition != .quarantinedConflict
        } catch {
            _ = await quarantine(claim)
            return false
        }
    }

    private func quarantine(_ claim: FinderCommandClaim) async -> Bool {
        do {
            try await coordinator.quarantine(claim)
            return true
        } catch {
            return false
        }
    }

    private func recordFailure(
        requestID: UUID,
        error: Error,
        now: Date,
        forcedCategory: AgentFailureCategory? = nil,
        forcedRetryable: Bool? = nil
    ) {
        let previousAttempts = store.existingDiagnostic(for: requestID)?.attempts ?? 0
        let attempts = previousAttempts + 1
        let safeError = error as? any AgentSafeDiagnosticError
        let category = forcedCategory ?? safeError?.agentFailureCategory ?? .internalFailure
        let retryable = forcedRetryable ?? safeError?.agentRetryable ?? false
        let summary = safeError?.agentSafeSummary ?? Self.genericSummary(for: category)
        let nextAttempt = retryable
            ? now.addingTimeInterval(Self.retryDelay(attempts: attempts))
            : nil
        let diagnostic = AgentFailureDiagnostic(
            requestID: requestID,
            category: category,
            summary: summary,
            attempts: attempts,
            lastAttemptAt: now,
            nextAttemptAt: nextAttempt,
            retryable: retryable
        )
        try? store.writeDiagnostic(diagnostic)
    }

    private static func lifecycleError(
        for command: FinderCommand,
        now: Date
    ) -> AgentRequestLifecycleError? {
        let age = now.timeIntervalSince(command.createdAt)
        if age > maximumRequestAge { return .expired }
        if age < -maximumFutureClockSkew { return .futureDated }
        return nil
    }

    private static func requiresMainApplication(_ command: FinderCommand) -> Bool {
        switch command.kind {
        case .add:
            return false
        case .update, .cleanup:
            guard command.paths.count == 1 else { return true }
            let root = URL(
                fileURLWithPath: command.workingCopyRoot,
                isDirectory: true
            ).standardizedFileURL.path
            let selected = URL(fileURLWithPath: command.paths[0]).standardizedFileURL.path
            return selected != root
        case .openApp, .refresh, .commit, .diff, .revert, .restoreBeforeRevision, .log, .resolve,
             .copyRepositoryURL, .ignoreName, .ignoreExtension:
            return true
        }
    }

    private static func postHandoffNotification() {
        DistributedNotificationCenter.default().postNotificationName(
            handoffNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private static func retryDelay(attempts: Int) -> TimeInterval {
        let exponent = min(max(attempts - 1, 0), 8)
        return min(5 * pow(2, Double(exponent)), 300)
    }

    private static func genericSummary(for category: AgentFailureCategory) -> String {
        switch category {
        case .invalidRequest:
            return "The Finder request failed validation and was not executed."
        case .registryUnavailable:
            return "The registered working-copy list is unavailable."
        case .requiresMainApplication:
            return "The command must be completed in the main application."
        case .executionFailed:
            return "The SVN operation failed without exposing command output."
        case .internalFailure:
            return "The Agent could not safely execute this request."
        }
    }
}
