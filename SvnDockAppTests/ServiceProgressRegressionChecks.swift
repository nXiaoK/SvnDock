import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum ServiceProgressRegressionChecks {
    @discardableResult
    static func run() async throws -> Bool {
        guard let executable = SVNExecutableLocator.defaultCandidatePaths.map({ URL(fileURLWithPath: $0) })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path)
                && FileManager.default.isExecutableFile(atPath: $0.deletingLastPathComponent()
                    .appendingPathComponent("svnadmin").path) }) else {
            print("SKIP service progress integration: SVN and svnadmin are unavailable")
            return false
        }
        let fixture = try ServiceProgressFixture(executable: executable)
        defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        try await fixture.create()
        try await liveCommitAndUpdate(fixture)
        try await failedCommitCannotFinishEarly(fixture)
        try await cancelledUpdateStopsBatch(fixture)
        print("Service progress regression passed: live commit/update output, exact selection, preflight, late failure, cancellation and closed delivery")
        return true
    }

    private static func liveCommitAndUpdate(_ fixture: ServiceProgressFixture) async throws {
        let service = try fixture.service(runner: fixture.runner)
        let copy = try await service.registerWorkingCopy(at: fixture.root)
        let peer = fixture.temporary.appendingPathComponent("peer")
        _ = try await fixture.svn(["checkout", fixture.repository.absoluteString, peer.path], in: fixture.temporary)
        try fixture.write("selected new content\n", to: fixture.selectedPath)
        try fixture.write("unselected local content\n", to: "unselected.txt")
        let commitEvents = ServiceProgressEvents()
        try await service.commit(workingCopy: copy, relativePaths: [fixture.selectedPath], message: "Commit selected file with progress") {
            commitEvents.append($0, whileRunning: fixture.runner.isMutationRunning)
        }
        let commitValues = commitEvents.snapshots
        try check(commitValues.first?.phase == .preparing && commitValues.contains { $0.phase == .processing },
                  "commit exposes preparation separately from the mutation")
        try check(commitEvents.receivedLiveItem && commitValues.last?.processedItemCount == 1,
                  "real commit reports its selected item before the process returns")
        try check(commitValues.allSatisfy { $0.currentPath == nil || $0.currentPath == fixture.selectedPath },
                  "any displayed commit path preserves Unicode and @")
        try check(try await fixture.svn(["cat", fixture.repository.appendingPathComponent("unselected.txt").absoluteString])
            .standardOutputString == "base\n", "progress does not recursively commit an unselected change")
        try check(try await fixture.revision() == "2", "progress commits the selection once")

        let peerCopy = try await service.registerWorkingCopy(at: peer)
        let updateEvents = ServiceProgressEvents()
        try await service.update(workingCopies: [peerCopy]) {
            updateEvents.append($0, whileRunning: fixture.runner.isMutationRunning)
        }
        try check(updateEvents.receivedLiveItem && updateEvents.snapshots.last?.processedItemCount == 1,
                  "real update reports its changed path before the process returns")
        try check(try String(contentsOf: peer.appendingPathComponent(fixture.selectedPath), encoding: .utf8)
            == "selected new content\n", "streamed update writes the complete server content")
        try check(fixture.runner.mutations == ["commit", "update"], "observing output never adds a mutation")

        let rejected = ServiceProgressEvents()
        do {
            try await service.commit(workingCopy: copy, relativePaths: [fixture.selectedPath], message: "Reject stale selection") {
                rejected.append($0)
            }
            throw ServiceProgressFailure("unchanged selection unexpectedly committed")
        } catch SVNSelectedCommitError.changedSelection { }
        try check(rejected.snapshots.map(\.phase) == [.preparing],
                  "a rejected preflight must not report mutation progress")
        try check(fixture.runner.mutations == ["commit", "update"], "preflight rejection launches no commit")
    }

    private static func failedCommitCannotFinishEarly(_ fixture: ServiceProgressFixture) async throws {
        try fixture.write("uncommitted retry content\n", to: fixture.selectedPath)
        let runner = ServiceHeldProgressRunner(base: fixture.runner, command: "commit")
        let service = try fixture.service(runner: runner)
        let copy = try await service.registerWorkingCopy(at: fixture.root)
        let events = ServiceProgressEvents()
        let task = Task {
            try await service.commit(workingCopy: copy, relativePaths: [fixture.selectedPath], message: "Exercise late command failure") {
                events.append($0)
            }
        }
        do {
            try await waitForEmission(runner)
            try check(events.snapshots.contains { $0.processedItemCount == 1 },
                      "a held process publishes output before command completion")
            try check(events.snapshots.contains { $0.phase == .awaitingServer },
                      "a server notification is still an in-progress phase until exit is checked")
            try check(!events.snapshots.contains { $0.currentPath?.contains("private-password") == true },
                      "stderr diagnostics never become progress paths")
            await runner.release()
            do {
                try await task.value
                throw ServiceProgressFailure("failed commit was reported as successful")
            } catch SVNSelectedCommitError.commandFailed(let detail) {
                try check(detail.contains("simulated late failure"), "exit failure remains observable after progress")
            }
        } catch {
            task.cancel()
            _ = try? await task.value
            throw error
        }
        let countAfterReturn = events.snapshots.count
        await runner.emitLateOutput()
        try check(events.snapshots.count == countAfterReturn, "late output cannot publish after a failed service call")
        let revisionAfterFailure = try await fixture.revision()
        try check(await runner.mutationCount == 1 && revisionAfterFailure == "2",
                  "failed progress does not retry or create a partial fixture commit")
    }

    private static func cancelledUpdateStopsBatch(_ fixture: ServiceProgressFixture) async throws {
        let runner = ServiceHeldProgressRunner(base: fixture.runner, command: "update")
        let service = try fixture.service(runner: runner)
        let copy = try await service.registerWorkingCopy(at: fixture.root)
        let events = ServiceProgressEvents()
        let task = Task {
            try await service.update(workingCopies: [copy, copy]) { events.append($0) }
        }
        do {
            try await waitForEmission(runner)
            try check(events.snapshots.contains { $0.processedItemCount == 1 }, "update publishes live output while held")
            task.cancel()
            do {
                try await task.value
                throw ServiceProgressFailure("cancelled update unexpectedly succeeded")
            } catch is CancellationError { }
        } catch {
            task.cancel()
            _ = try? await task.value
            throw error
        }
        let countAfterReturn = events.snapshots.count
        await runner.emitLateOutput()
        try check(events.snapshots.count == countAfterReturn, "late output cannot publish after cancellation")
        try check(await runner.mutationCount == 1, "cancellation stops the remaining update batch without retries")
    }

    private static func waitForEmission(_ runner: ServiceHeldProgressRunner) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await runner.didEmit), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(await runner.didEmit, "timed out waiting for live process output")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw ServiceProgressFailure(message) }
    }
}

private struct ServiceProgressFailure: Error { let message: String; init(_ message: String) { self.message = message } }

private final class ServiceProgressEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SVNProgressSnapshot] = []
    private var live = false
    var snapshots: [SVNProgressSnapshot] { lock.withLock { values } }
    var receivedLiveItem: Bool { lock.withLock { live } }
    func append(_ value: SVNProgressSnapshot, whileRunning: Bool = false) {
        lock.withLock {
            values.append(value)
            if whileRunning && value.processedItemCount > 0 { live = true }
        }
    }
}

private struct ServiceProgressFixture: Sendable {
    let executable: URL
    let temporary: URL
    let repository: URL
    let root: URL
    let runner: ServiceIsolatedProgressRunner
    let selectedPath = "selected 测试@name.txt"

    init(executable: URL) throws {
        self.executable = executable
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("svndock-progress-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        repository = temporary.appendingPathComponent("repository")
        root = temporary.appendingPathComponent("wc")
        runner = ServiceIsolatedProgressRunner(configuration: temporary.appendingPathComponent("svn-config"))
    }

    func create() async throws {
        let result = try await ProcessRunner().run(ProcessInvocation(
            executableURL: executable.deletingLastPathComponent().appendingPathComponent("svnadmin"),
            arguments: ["create", repository.path]
        ))
        guard result.succeeded else { throw ServiceProgressFailure("fixture repository creation failed") }
        _ = try await svn(["checkout", repository.absoluteString, root.path], in: temporary)
        for path in [selectedPath, "unselected.txt"] { try write("base\n", to: path) }
        _ = try await svn(["add", "--force", "--", "."])
        _ = try await svn(["commit", "-m", "Seed progress fixture", "--", "."])
        runner.resetMutations()
    }

    func write(_ text: String, to path: String) throws { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }

    func service(runner: any ProcessRunning) throws -> CoreSvnDockService {
        try CoreSvnDockService(sharedStore: FinderSharedStore(directoryURL: temporary.appendingPathComponent("shared-\(UUID())")),
            executableLocator: SVNExecutableLocator(candidatePaths: [executable.path], environmentOverrideKey: "SVNDOCK_PROGRESS_TEST_UNUSED"),
            processRunner: runner)
    }

    func svn(_ arguments: [String], in directory: URL? = nil) async throws -> ProcessResult {
        let result = try await runner.run(ProcessInvocation(executableURL: executable, arguments: arguments,
            currentDirectoryURL: directory ?? root, environment: ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]))
        guard result.succeeded else { throw ServiceProgressFailure("fixture SVN failed: \(result.standardErrorString)") }
        return result
    }

    func revision() async throws -> String {
        try await svn(["info", "--show-item", "revision", repository.absoluteString]).standardOutputString
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class ServiceIsolatedProgressRunner: ProcessRunning, @unchecked Sendable {
    let configuration: URL
    private let lock = NSLock()
    private var active = false
    private var commands: [String] = []
    var isMutationRunning: Bool { lock.withLock { active } }
    var mutations: [String] { lock.withLock { commands } }
    init(configuration: URL) { self.configuration = configuration }
    func resetMutations() { lock.withLock { commands = [] } }
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        try await run(invocation, onOutput: { _ in })
    }
    func run(_ invocation: ProcessInvocation, onOutput: @escaping @Sendable (ProcessOutputChunk) -> Void) async throws -> ProcessResult {
        let mutation = invocation.arguments.first == "commit" || invocation.arguments.first == "update"
        if mutation { lock.withLock { active = true; commands.append(invocation.arguments[0]) } }
        defer { if mutation { lock.withLock { active = false } } }
        return try await ProcessRunner().run(ProcessInvocation(executableURL: invocation.executableURL,
            arguments: ["--config-dir", configuration.path, "--no-auth-cache", "--non-interactive"] + invocation.arguments,
            currentDirectoryURL: invocation.currentDirectoryURL, environment: invocation.environment,
            standardInput: invocation.standardInput,
            argumentFiles: invocation.argumentFiles.map { ProcessArgumentFile(argumentIndex: $0.argumentIndex + 4, contents: $0.contents) },
            outputByteLimit: invocation.outputByteLimit), onOutput: onOutput)
    }
}

private actor ServiceHeldProgressRunner: ProcessRunning {
    let base: any ProcessRunning
    let command: String
    private var released = false
    private var callback: (@Sendable (ProcessOutputChunk) -> Void)?
    private(set) var didEmit = false
    private(set) var mutationCount = 0
    init(base: any ProcessRunning, command: String) { self.base = base; self.command = command }
    func release() { released = true }
    func emitLateOutput() { callback?(ProcessOutputChunk(stream: .standardOutput, data: Data("Adding         stale.txt\n".utf8))) }
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult { try await base.run(invocation) }
    func run(_ invocation: ProcessInvocation, onOutput: @escaping @Sendable (ProcessOutputChunk) -> Void) async throws -> ProcessResult {
        guard invocation.arguments.first == command else { return try await base.run(invocation, onOutput: onOutput) }
        mutationCount += 1
        callback = onOutput
        let notification = command == "commit" ? "Sending        selected 测试@name.txt\nTransmitting file data .done\nCommitting transaction...\nCommitted revision 999.\n"
            : "U    selected 测试@name.txt\nUpdated to revision 999.\n"
        let bytes = Data(notification.utf8)
        onOutput(ProcessOutputChunk(stream: .standardOutput, data: bytes.prefix(5)))
        onOutput(ProcessOutputChunk(stream: .standardOutput, data: bytes.dropFirst(5)))
        onOutput(ProcessOutputChunk(stream: .standardError, data: Data("https://user:private-password@example.invalid/error\n".utf8)))
        didEmit = true
        while !released { try await Task.sleep(for: .milliseconds(10)) }
        return ProcessResult(terminationStatus: 1, terminationReason: .exit, standardOutput: bytes,
            standardError: Data("simulated late failure".utf8))
    }
}
