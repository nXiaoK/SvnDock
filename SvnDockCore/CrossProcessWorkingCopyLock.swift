import Darwin
import Foundation

// Darwin also imports `struct flock`, which shadows the two-argument C
// function in qualified Swift lookup. Keep one module-wide declaration of the
// libc symbol and route every call through it; mixing this declaration with
// direct imported calls breaks whole-module optimization in Release builds.
@_silgen_name("flock")
func svnDockFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// Failures raised while preparing or acquiring a cross-process working-copy lock.
public enum CrossProcessWorkingCopyLockError: Error, LocalizedError, Equatable, Sendable {
    case invalidBaseDirectory
    case invalidPollInterval
    case cannotPrepareBaseDirectory(String)
    case unsafeBaseDirectory
    case unsafeLockDirectory
    case unsafeLockFile
    case systemCallFailed(operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseDirectory:
            return "The shared lock base must be an absolute, non-root file URL."
        case .invalidPollInterval:
            return "The lock polling interval must be greater than zero."
        case let .cannotPrepareBaseDirectory(reason):
            return "Unable to prepare the shared lock base: \(reason)"
        case .unsafeBaseDirectory:
            return "The shared lock base is not a safe directory owned by the current user."
        case .unsafeLockDirectory:
            return "The operation-locks path is not a safe directory owned by the current user."
        case .unsafeLockFile:
            return "The working-copy lock path is not a safe regular file owned by the current user."
        case let .systemCallFailed(operation, code):
            return "The \(operation) system call failed with errno \(code)."
        }
    }
}

/// Coordinates SVN access to one working copy across the app and background Agent.
///
/// Locks live below the shared App Group base at
/// `operation-locks/<working-copy UUID>.lock`. Acquisition uses non-blocking
/// `flock(2)` with cancellation-aware polling. The descriptor is close-on-exec,
/// so an invoked `svn` child cannot accidentally extend the lease; closing the
/// descriptor, including process teardown after a crash, releases the lock.
public struct CrossProcessWorkingCopyLock: Sendable {
    public static let lockDirectoryName = "operation-locks"

    public let baseDirectoryURL: URL
    public let pollInterval: Duration

    public init(
        baseDirectoryURL: URL,
        pollInterval: Duration = .milliseconds(50)
    ) throws {
        let standardized = baseDirectoryURL.standardizedFileURL
        guard standardized.isFileURL,
              standardized.path.hasPrefix("/"),
              standardized.path != "/",
              !standardized.path.contains("\0") else {
            throw CrossProcessWorkingCopyLockError.invalidBaseDirectory
        }
        guard pollInterval > .zero else {
            throw CrossProcessWorkingCopyLockError.invalidPollInterval
        }

        self.baseDirectoryURL = standardized
        self.pollInterval = pollInterval
    }

    public var lockDirectoryURL: URL {
        baseDirectoryURL.appendingPathComponent(Self.lockDirectoryName, isDirectory: true)
    }

    public func lockFileURL(for workingCopyID: UUID) -> URL {
        lockDirectoryURL.appendingPathComponent(
            Self.lockFileName(for: workingCopyID),
            isDirectory: false
        )
    }

    /// Acquires the exclusive lease, runs `operation`, and always releases the
    /// descriptor afterward. Cancellation while waiting throws promptly. Once
    /// the operation starts, cancellation remains cooperative with that closure.
    public func withLock<Result: Sendable>(
        for workingCopyID: UUID,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        let descriptor = try openLockFile(for: workingCopyID)
        defer {
            _ = svnDockFlock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
        }

        while true {
            try Task.checkCancellation()
            if svnDockFlock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                try Task.checkCancellation()
                return try await operation()
            }

            let code = errno
            if code == EINTR {
                continue
            }
            if code == EWOULDBLOCK || code == EAGAIN {
                try await Task<Never, Never>.sleep(for: pollInterval)
                continue
            }
            throw CrossProcessWorkingCopyLockError.systemCallFailed(
                operation: "flock",
                code: code
            )
        }
    }

    private func openLockFile(for workingCopyID: UUID) throws -> Int32 {
        do {
            try FileManager.default.createDirectory(
                at: baseDirectoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw CrossProcessWorkingCopyLockError.cannotPrepareBaseDirectory(
                error.localizedDescription
            )
        }

        let baseDescriptor = Darwin.open(
            baseDirectoryURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard baseDescriptor >= 0 else {
            let code = errno
            if code == ELOOP || code == ENOTDIR {
                throw CrossProcessWorkingCopyLockError.unsafeBaseDirectory
            }
            throw CrossProcessWorkingCopyLockError.systemCallFailed(
                operation: "open shared lock base",
                code: code
            )
        }
        defer { _ = Darwin.close(baseDescriptor) }

        guard Self.isSafeDirectory(descriptor: baseDescriptor) else {
            throw CrossProcessWorkingCopyLockError.unsafeBaseDirectory
        }

        if Darwin.mkdirat(baseDescriptor, Self.lockDirectoryName, 0o700) != 0 {
            let code = errno
            guard code == EEXIST else {
                throw CrossProcessWorkingCopyLockError.systemCallFailed(
                    operation: "mkdirat operation-locks",
                    code: code
                )
            }
        }

        let directoryDescriptor = Darwin.openat(
            baseDescriptor,
            Self.lockDirectoryName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            let code = errno
            if code == ELOOP || code == ENOTDIR {
                throw CrossProcessWorkingCopyLockError.unsafeLockDirectory
            }
            throw CrossProcessWorkingCopyLockError.systemCallFailed(
                operation: "openat operation-locks",
                code: code
            )
        }
        defer { _ = Darwin.close(directoryDescriptor) }

        guard Self.isSafeDirectory(descriptor: directoryDescriptor),
              Darwin.fchmod(directoryDescriptor, 0o700) == 0 else {
            throw CrossProcessWorkingCopyLockError.unsafeLockDirectory
        }

        let descriptor = Darwin.openat(
            directoryDescriptor,
            Self.lockFileName(for: workingCopyID),
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP || code == EISDIR {
                throw CrossProcessWorkingCopyLockError.unsafeLockFile
            }
            throw CrossProcessWorkingCopyLockError.systemCallFailed(
                operation: "openat working-copy lock",
                code: code
            )
        }

        guard Self.isSafeRegularFile(descriptor: descriptor),
              Darwin.fchmod(descriptor, 0o600) == 0 else {
            _ = Darwin.close(descriptor)
            throw CrossProcessWorkingCopyLockError.unsafeLockFile
        }
        return descriptor
    }

    private static func lockFileName(for workingCopyID: UUID) -> String {
        workingCopyID.uuidString.lowercased() + ".lock"
    }

    private static func isSafeDirectory(descriptor: Int32) -> Bool {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else { return false }
        return value.st_uid == Darwin.geteuid()
            && (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && (value.st_mode & 0o022) == 0
    }

    private static func isSafeRegularFile(descriptor: Int32) -> Bool {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else { return false }
        return value.st_uid == Darwin.geteuid()
            && value.st_nlink == 1
            && (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && (value.st_mode & 0o022) == 0
    }
}
