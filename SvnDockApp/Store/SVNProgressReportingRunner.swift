import Foundation
import SvnDockCore

/// Observes only the final mutation. Selected-commit preflight still uses the
/// same runner, scheduler and lock, without interpreting its XML as progress.
struct SVNProgressReportingRunner: ProcessRunning {
    private let base: any ProcessRunning
    private let progress: @Sendable (SVNProgressSnapshot) -> Void

    init(base: any ProcessRunning, progress: @escaping @Sendable (SVNProgressSnapshot) -> Void) {
        self.base = base
        self.progress = progress
    }

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        guard invocation.arguments.first == "commit" || invocation.arguments.first == "update" else {
            return try await base.run(invocation)
        }
        let observer = SVNProgressObserver(progress: progress)
        defer { observer.finish() }
        progress(SVNProgressSnapshot(phase: .processing))
        return try await base.run(invocation, onOutput: { observer.consume($0) })
    }
}

/// The process drains stdout and stderr off the service actor. Serialize parser
/// access and close delivery when the invocation ends, including cancellation.
private final class SVNProgressObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = SVNProgressParser()
    private var isFinished = false
    private let progress: @Sendable (SVNProgressSnapshot) -> Void

    init(progress: @escaping @Sendable (SVNProgressSnapshot) -> Void) {
        self.progress = progress
    }

    func consume(_ chunk: ProcessOutputChunk) {
        lock.withLock {
            guard !isFinished else { return }
            if let snapshot = parser.consume(chunk) { progress(snapshot) }
        }
    }

    func finish() {
        lock.withLock {
            guard !isFinished else { return }
            isFinished = true
            if let snapshot = parser.finish() { progress(snapshot) }
        }
    }
}
