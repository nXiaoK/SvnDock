import Foundation

public struct ProcessInvocation: Hashable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let currentDirectoryURL: URL?
    /// Values are merged over the app's inherited environment.
    public let environment: [String: String]
    public let standardInput: Data?

    public init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String] = [:],
        standardInput: Data? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
        self.environment = environment
        self.standardInput = standardInput
    }
}

public enum ProcessTermination: Hashable, Sendable {
    case exit
    case uncaughtSignal
}

public struct ProcessResult: Hashable, Sendable {
    public let terminationStatus: Int32
    public let terminationReason: ProcessTermination
    public let standardOutput: Data
    public let standardError: Data

    public init(
        terminationStatus: Int32,
        terminationReason: ProcessTermination,
        standardOutput: Data,
        standardError: Data
    ) {
        self.terminationStatus = terminationStatus
        self.terminationReason = terminationReason
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool {
        terminationReason == .exit && terminationStatus == 0
    }

    public var standardOutputString: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    public var standardErrorString: String {
        String(decoding: standardError, as: UTF8.self)
    }
}

public enum ProcessRunnerError: Error, LocalizedError, Equatable, Sendable {
    case invalidInvocation(String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidInvocation(reason):
            return "Invalid process invocation: \(reason)"
        case let .launchFailed(reason):
            return "Unable to launch process: \(reason)"
        }
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult
}

/// Executes commands directly with `Foundation.Process`; no shell is involved.
///
/// stdout and stderr are drained concurrently so a verbose SVN command cannot
/// deadlock after filling a pipe. Cancelling the calling task terminates the
/// child process and ultimately throws `CancellationError`.
public struct ProcessRunner: ProcessRunning, Sendable {
    public init() {}

    public func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        try Self.validate(invocation)
        try Task.checkCancellation()

        let state = RunningProcessState()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: nil) {
                try Self.runBlocking(invocation, state: state)
            }.value
        } onCancel: {
            state.cancel()
        }
    }

    private static func validate(_ invocation: ProcessInvocation) throws {
        guard invocation.executableURL.isFileURL,
              invocation.executableURL.path.hasPrefix("/") else {
            throw ProcessRunnerError.invalidInvocation("executable must be an absolute file URL")
        }

        if let directory = invocation.currentDirectoryURL,
           (!directory.isFileURL || !directory.path.hasPrefix("/")) {
            throw ProcessRunnerError.invalidInvocation("working directory must be an absolute file URL")
        }

        guard invocation.arguments.allSatisfy({ !$0.contains("\0") }) else {
            throw ProcessRunnerError.invalidInvocation("arguments cannot contain NUL bytes")
        }

        guard invocation.environment.allSatisfy({ key, value in
            !key.isEmpty && !key.contains("=") && !key.contains("\0") && !value.contains("\0")
        }) else {
            throw ProcessRunnerError.invalidInvocation("environment contains an invalid key or value")
        }
    }

    private static func runBlocking(
        _ invocation: ProcessInvocation,
        state: RunningProcessState
    ) throws -> ProcessResult {
        if state.isCancelled {
            throw CancellationError()
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()

        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.currentDirectoryURL
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe

        if !invocation.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(
                invocation.environment,
                uniquingKeysWith: { _, newValue in newValue }
            )
        }

        guard state.install(process) else {
            throw CancellationError()
        }

        do {
            try process.run()
        } catch {
            state.clear(process)
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        let output = LockedData()
        let errors = LockedData()
        let drains = DispatchGroup()

        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            output.set(outputPipe.fileHandleForReading.readDataToEndOfFile())
            drains.leave()
        }

        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            errors.set(errorPipe.fileHandleForReading.readDataToEndOfFile())
            drains.leave()
        }

        if let standardInput = invocation.standardInput, !standardInput.isEmpty {
            do {
                try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
            } catch {
                // A command is allowed to close stdin early; its exit status and
                // stderr are more useful than turning that into a launch error.
            }
        }
        try? inputPipe.fileHandleForWriting.close()

        if state.isCancelled, process.isRunning {
            process.terminate()
        }

        process.waitUntilExit()
        drains.wait()
        state.clear(process)

        if state.isCancelled {
            throw CancellationError()
        }

        let reason: ProcessTermination = process.terminationReason == .exit
            ? .exit
            : .uncaughtSignal

        return ProcessResult(
            terminationStatus: process.terminationStatus,
            terminationReason: reason,
            standardOutput: output.value,
            standardError: errors.value
        )
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var value: Data {
        lock.withLock { storage }
    }

    func set(_ data: Data) {
        lock.withLock { storage = data }
    }
}

private final class RunningProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func install(_ process: Process) -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            self.process = process
            return true
        }
    }

    func clear(_ process: Process) {
        lock.withLock {
            if self.process === process {
                self.process = nil
            }
        }
    }

    func cancel() {
        let processToTerminate: Process? = lock.withLock {
            cancelled = true
            return process
        }

        if let processToTerminate, processToTerminate.isRunning {
            processToTerminate.terminate()
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
