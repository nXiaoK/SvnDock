import Foundation

/// Serializes operations per working copy while allowing different working
/// copies to make progress concurrently.
///
/// This protects `.svn/wc.db` from overlapping writes without imposing a
/// global queue across unrelated repositories.
public actor WorkingCopyOperationScheduler {
    private struct Tail: Sendable {
        let token: UUID
        let completion: Task<Void, Never>
    }

    private var tails: [UUID: Tail] = [:]

    public init() {}

    public var scheduledWorkingCopyCount: Int {
        tails.count
    }

    public func hasScheduledOperation(for workingCopyID: UUID) -> Bool {
        tails[workingCopyID] != nil
    }

    public func enqueue<Result: Sendable>(
        for workingCopyID: UUID,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        let previous = tails[workingCopyID]?.completion
        let token = UUID()

        let task = Task<Result, Error> {
            if let previous {
                await previous.value
            }
            try Task.checkCancellation()
            return try await operation()
        }

        let completion = Task<Void, Never> {
            _ = await task.result
        }
        tails[workingCopyID] = Tail(token: token, completion: completion)

        do {
            let value = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            removeTail(for: workingCopyID, ifTokenMatches: token)
            return value
        } catch {
            removeTail(for: workingCopyID, ifTokenMatches: token)
            throw error
        }
    }

    public func enqueue<Result: Sendable>(
        _ operation: SVNOperation,
        execute: @escaping @Sendable (SVNOperation) async throws -> Result
    ) async throws -> Result {
        try await enqueue(for: operation.workingCopyID) {
            try await execute(operation)
        }
    }

    private func removeTail(for workingCopyID: UUID, ifTokenMatches token: UUID) {
        guard tails[workingCopyID]?.token == token else { return }
        tails.removeValue(forKey: workingCopyID)
    }
}
