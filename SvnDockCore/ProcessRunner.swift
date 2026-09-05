import Foundation
import Darwin

/// A private temporary input file whose path replaces one argument at launch.
/// The runner owns its lifetime, including cleanup after failure/cancellation.
public struct ProcessArgumentFile: Hashable, Sendable {
    public let argumentIndex: Int
    public let contents: Data

    public init(argumentIndex: Int, contents: Data) {
        self.argumentIndex = argumentIndex
        self.contents = contents
    }
}

public struct ProcessInvocation: Hashable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let currentDirectoryURL: URL?
    /// Values are merged over the app's inherited environment.
    public let environment: [String: String]
    public let standardInput: Data?
    public let argumentFiles: [ProcessArgumentFile]

    public init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String] = [:],
        standardInput: Data? = nil,
        argumentFiles: [ProcessArgumentFile] = []
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
        self.environment = environment
        self.standardInput = standardInput
        self.argumentFiles = argumentFiles
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
            // Process.waitUntilExit and FileHandle I/O block threads. Keep them
            // off Swift's cooperative executor so other async work can run even
            // when several repositories have commands in flight.
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result {
                        try Self.runBlocking(invocation, state: state)
                    })
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    private static func validate(_ invocation: ProcessInvocation) throws {
        // Foundation can raise NSInvalidArgumentException here, which Swift
        // do/catch cannot catch. Leave one slot for the executable (argv[0]).
        guard invocation.arguments.count < 4_096 else {
            throw ProcessRunnerError.invalidInvocation("too many command arguments; use a targets file")
        }

        var fileIndices = Set<Int>()
        for file in invocation.argumentFiles {
            guard invocation.arguments.indices.contains(file.argumentIndex),
                  fileIndices.insert(file.argumentIndex).inserted else {
                throw ProcessRunnerError.invalidInvocation("invalid or duplicate argument file index")
            }
        }

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
        let inputPipe = invocation.standardInput == nil ? nil : Pipe()
        if let inputPipe,
           Darwin.fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == -1 {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            throw ProcessRunnerError.launchFailed("Unable to configure standard input: \(error.localizedDescription)")
        }

        var temporaryDirectory: URL?
        defer {
            if let temporaryDirectory {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }
        var arguments = invocation.arguments
        if !invocation.argumentFiles.isEmpty {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("SvnDock-process-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                temporaryDirectory = directory
                for file in invocation.argumentFiles {
                    let url = directory.appendingPathComponent("input-\(file.argumentIndex)")
                    try file.contents.write(to: url, options: .withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    arguments[file.argumentIndex] = url.path
                }
            } catch {
                throw ProcessRunnerError.launchFailed(error.localizedDescription)
            }
        }

        let environment = ProcessInfo.processInfo.environment.merging(
            invocation.environment,
            uniquingKeysWith: { _, newValue in newValue }
        )
        let argumentBytes = arguments.reduce(invocation.executableURL.path.utf8.count + 1) {
            $0 + $1.utf8.count + 1
        }
        let environmentBytes = environment.reduce(0) {
            $0 + $1.key.utf8.count + $1.value.utf8.count + 2
        }
        let pointerBytes = (arguments.count + environment.count + 3) * MemoryLayout<UnsafeRawPointer>.size
        let byteLimit = sysconf(_SC_ARG_MAX)
        guard byteLimit <= 0 || argumentBytes + environmentBytes + pointerBytes < byteLimit else {
            throw ProcessRunnerError.invalidInvocation("command arguments and environment exceed the system size limit")
        }

        process.executableURL = invocation.executableURL
        process.arguments = arguments
        process.currentDirectoryURL = invocation.currentDirectoryURL
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        if let inputPipe {
            process.standardInput = inputPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        process.environment = environment

        guard state.install(process) else {
            throw CancellationError()
        }

        do {
            try process.run()
            state.didLaunch(process)
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

        if let inputPipe, let standardInput = invocation.standardInput, !standardInput.isEmpty {
            do {
                try writeStandardInput(standardInput, to: inputPipe.fileHandleForWriting)
            } catch {
                // A command is allowed to close stdin early; its exit status and
                // stderr are more useful than turning that into a launch error.
            }
        }
        try? inputPipe?.fileHandleForWriting.close()

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

    private static func writeStandardInput(_ data: Data, to handle: FileHandle) throws {
        // A child can close stdin before consuming it (including on cancel).
        // F_SETNOSIGPIPE on this private pipe converts that into EPIPE without
        // changing the app's signal handlers or other threads' signal masks.
        // Write directly so partial writes and interruptions remain explicit.
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(handle.fileDescriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if written > 0 {
                    offset += written
                } else {
                    let error = written == 0 ? EIO : errno
                    if error == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
                }
            }
        }
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
    private var launched = false
    private var terminationRequested = false

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

    func didLaunch(_ process: Process) {
        lock.withLock {
            guard self.process === process else { return }
            launched = true
            if cancelled { terminateLocked() }
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if launched { terminateLocked() }
        }
    }

    private func terminateLocked() {
        guard !terminationRequested, let process, process.isRunning else { return }
        terminationRequested = true
        process.terminate()
        // SVN normally handles SIGTERM and releases its locks. A stuck helper
        // may ignore it; allow cleanup time, then ensure cancellation finishes.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self, weak process] in
            guard let self, let process else { return }
            self.lock.withLock {
                guard self.process === process, process.isRunning else { return }
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
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
