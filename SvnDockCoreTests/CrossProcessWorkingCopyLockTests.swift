import Foundation
import XCTest
@testable import SvnDockCore

final class CrossProcessWorkingCopyLockTests: XCTestCase {
    func testCreatesPrivateStableLockPathAndReturnsOperationValue() async throws {
        let temporary = try TemporaryDirectory()
        let workingCopyID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let lock = try CrossProcessWorkingCopyLock(
            baseDirectoryURL: temporary.url,
            pollInterval: .milliseconds(5)
        )

        let result = try await lock.withLock(for: workingCopyID) { "completed" }

        XCTAssertEqual(result, "completed")
        XCTAssertEqual(
            lock.lockFileURL(for: workingCopyID).lastPathComponent,
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.lock"
        )
        XCTAssertEqual(try permissions(at: lock.lockDirectoryURL), 0o700)
        XCTAssertEqual(try permissions(at: lock.lockFileURL(for: workingCopyID)), 0o600)
    }

    func testCancellationWhileAnotherProcessOwnsLockDoesNotRunOperation() async throws {
        let temporary = try TemporaryDirectory()
        let workingCopyID = UUID()
        let lock = try CrossProcessWorkingCopyLock(
            baseDirectoryURL: temporary.url,
            pollInterval: .milliseconds(5)
        )
        _ = try await lock.withLock(for: workingCopyID) { () }

        let holder = try ExternalLockHolder(
            lockFileURL: lock.lockFileURL(for: workingCopyID),
            holdSeconds: 5
        )
        defer { holder.stop() }
        try holder.waitUntilLocked()

        let operationProbe = OperationProbe()
        let waiter = Task {
            try await lock.withLock(for: workingCopyID) {
                await operationProbe.markExecuted()
            }
        }
        try await Task<Never, Never>.sleep(for: .milliseconds(40))
        waiter.cancel()

        do {
            try await waiter.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let didExecute = await operationProbe.didExecute
        XCTAssertFalse(didExecute)
    }

    func testExternalProcessExitAutomaticallyReleasesLock() async throws {
        let temporary = try TemporaryDirectory()
        let workingCopyID = UUID()
        let lock = try CrossProcessWorkingCopyLock(
            baseDirectoryURL: temporary.url,
            pollInterval: .milliseconds(5)
        )
        _ = try await lock.withLock(for: workingCopyID) { () }

        let holder = try ExternalLockHolder(
            lockFileURL: lock.lockFileURL(for: workingCopyID),
            holdSeconds: 0.4
        )
        defer { holder.stop() }
        try holder.waitUntilLocked()

        let clock = ContinuousClock()
        let started = clock.now
        let result = try await lock.withLock(for: workingCopyID) { "acquired" }
        let elapsed = started.duration(to: clock.now)

        XCTAssertEqual(result, "acquired")
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(100))
    }

    func testThrowingOperationReleasesLock() async throws {
        let temporary = try TemporaryDirectory()
        let workingCopyID = UUID()
        let lock = try CrossProcessWorkingCopyLock(
            baseDirectoryURL: temporary.url,
            pollInterval: .milliseconds(5)
        )

        do {
            let _: Void = try await lock.withLock(for: workingCopyID) {
                throw ExpectedError.operationFailed
            }
            XCTFail("Expected operation failure")
        } catch ExpectedError.operationFailed {
            // Expected.
        }

        let result = try await lock.withLock(for: workingCopyID) { 42 }
        XCTAssertEqual(result, 42)
    }

    func testRejectsSymlinkAtLockFilePath() async throws {
        let temporary = try TemporaryDirectory()
        let workingCopyID = UUID()
        let lock = try CrossProcessWorkingCopyLock(
            baseDirectoryURL: temporary.url,
            pollInterval: .milliseconds(5)
        )
        try FileManager.default.createDirectory(
            at: lock.lockDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let outsideFile = temporary.url.appendingPathComponent("outside.lock")
        XCTAssertTrue(FileManager.default.createFile(atPath: outsideFile.path, contents: Data()))
        try FileManager.default.createSymbolicLink(
            at: lock.lockFileURL(for: workingCopyID),
            withDestinationURL: outsideFile
        )

        do {
            _ = try await lock.withLock(for: workingCopyID) { true }
            XCTFail("Expected an unsafe lock-file error")
        } catch let error as CrossProcessWorkingCopyLockError {
            XCTAssertEqual(error, .unsafeLockFile)
        }
    }

    func testRejectsSymlinkAtLockDirectoryPath() async throws {
        let temporary = try TemporaryDirectory()
        let outsideDirectory = temporary.url.appendingPathComponent(
            "outside-directory",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outsideDirectory,
            withIntermediateDirectories: false
        )
        let lock = try CrossProcessWorkingCopyLock(
            baseDirectoryURL: temporary.url,
            pollInterval: .milliseconds(5)
        )
        try FileManager.default.createSymbolicLink(
            at: lock.lockDirectoryURL,
            withDestinationURL: outsideDirectory
        )

        do {
            _ = try await lock.withLock(for: UUID()) { true }
            XCTFail("Expected an unsafe lock-directory error")
        } catch let error as CrossProcessWorkingCopyLockError {
            XCTAssertEqual(error, .unsafeLockDirectory)
        }
    }

    func testRejectsUnsafeBaseAndPollingConfiguration() throws {
        XCTAssertThrowsError(try CrossProcessWorkingCopyLock(
            baseDirectoryURL: URL(string: "https://example.invalid/shared")!
        )) { error in
            XCTAssertEqual(error as? CrossProcessWorkingCopyLockError, .invalidBaseDirectory)
        }
        XCTAssertThrowsError(try CrossProcessWorkingCopyLock(
            baseDirectoryURL: URL(fileURLWithPath: "/", isDirectory: true)
        )) { error in
            XCTAssertEqual(error as? CrossProcessWorkingCopyLockError, .invalidBaseDirectory)
        }
        XCTAssertThrowsError(try CrossProcessWorkingCopyLock(
            baseDirectoryURL: FileManager.default.temporaryDirectory,
            pollInterval: .zero
        )) { error in
            XCTAssertEqual(error as? CrossProcessWorkingCopyLockError, .invalidPollInterval)
        }
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private enum ExpectedError: Error {
    case operationFailed
}

private actor OperationProbe {
    private(set) var didExecute = false

    func markExecuted() {
        didExecute = true
    }
}

private final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "svndock-cross-process-lock-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A separate process is important here: this verifies the actual OS-level
/// contract rather than merely coordinating two Swift tasks in one runtime.
private final class ExternalLockHolder {
    private let process: Process
    private let output: Pipe

    init(lockFileURL: URL, holdSeconds: Double) throws {
        let perlURL = URL(fileURLWithPath: "/usr/bin/perl")
        guard FileManager.default.isExecutableFile(atPath: perlURL.path) else {
            throw XCTSkip("/usr/bin/perl is unavailable for the cross-process flock test")
        }

        process = Process()
        output = Pipe()
        process.executableURL = perlURL
        process.arguments = [
            "-e",
            "use Fcntl qw(:flock); use IO::Handle; "
                + "open(my $fh, '+<', $ARGV[0]) or die; "
                + "flock($fh, LOCK_EX) or die; "
                + "STDOUT->autoflush(1); print \"locked\\n\"; "
                + "select(undef, undef, undef, $ARGV[1]);",
            lockFileURL.path,
            String(holdSeconds)
        ]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
    }

    func waitUntilLocked() throws {
        let data = output.fileHandleForReading.availableData
        guard String(decoding: data, as: UTF8.self) == "locked\n" else {
            process.waitUntilExit()
            throw ExternalHolderError.failedToAcquire
        }
    }

    func stop() {
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
    }
}

private enum ExternalHolderError: Error {
    case failedToAcquire
}
