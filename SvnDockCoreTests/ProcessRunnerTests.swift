import Foundation
import XCTest
@testable import SvnDockCore

final class ProcessRunnerTests: XCTestCase {
    func testCapturesStandardOutputAndDoesNotUseShell() async throws {
        let runner = ProcessRunner()
        let value = "hello; echo this-is-data"
        let invocation = ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", value]
        )

        let result = try await runner.run(invocation)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.standardOutputString, value)
        XCTAssertEqual(result.standardErrorString, "")
    }

    func testPassesStandardInput() async throws {
        let runner = ProcessRunner()
        let input = Data("payload\nwith unicode: 测试".utf8)
        let invocation = ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            standardInput: input
        )

        let result = try await runner.run(invocation)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.standardOutput, input)
    }

    func testReturnsNonzeroExitAsResult() async throws {
        let result = try await ProcessRunner().run(ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: []
        ))

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.terminationReason, .exit)
        XCTAssertNotEqual(result.terminationStatus, 0)
    }

    func testReadsArgumentFileAndStandardInput() async throws {
        let result = try await ProcessRunner().run(ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: ["", "-"],
            standardInput: Data("stdin".utf8),
            argumentFiles: [ProcessArgumentFile(argumentIndex: 0, contents: Data("file\n".utf8))]
        ))

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.standardOutputString, "file\nstdin")
    }

    func testRemovesArgumentFileAfterExit() async throws {
        let result = try await ProcessRunner().run(ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", ""],
            argumentFiles: [ProcessArgumentFile(argumentIndex: 1, contents: Data("targets".utf8))]
        ))

        XCTAssertTrue(result.succeeded)
        let file = URL(fileURLWithPath: result.standardOutputString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    func testRejectsExcessiveArgumentCountAndBytesWithoutCrashing() async throws {
        for arguments in [Array(repeating: "x", count: 60_372), [String(repeating: "x", count: 2_000_000)]] {
            do {
                _ = try await ProcessRunner().run(ProcessInvocation(
                    executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                    arguments: arguments
                ))
                XCTFail("Expected invalid invocation")
            } catch let error as ProcessRunnerError {
                guard case .invalidInvocation = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testRejectsInvalidArgumentFileIndex() async throws {
        do {
            _ = try await ProcessRunner().run(ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: [],
                argumentFiles: [ProcessArgumentFile(argumentIndex: 0, contents: Data())]
            ))
            XCTFail("Expected invalid invocation")
        } catch let error as ProcessRunnerError {
            guard case .invalidInvocation = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsNULArgumentBeforeLaunch() async {
        do {
            _ = try await ProcessRunner().run(ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: ["bad\0argument"]
            ))
            XCTFail("Expected invalid invocation")
        } catch let error as ProcessRunnerError {
            guard case .invalidInvocation = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellationTerminatesChild() async {
        let task = Task {
            try await ProcessRunner().run(ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"]
            ))
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNoStandardInputIsImmediateEndOfFile() async throws {
        let result = try await ProcessRunner().run(ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: []
        ))
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.standardOutput.isEmpty)
    }

    func testLargeStandardInputIsDrainedWithoutDeadlock() async throws {
        let input = Data(repeating: 0x61, count: 2_000_000)
        let result = try await ProcessRunner().run(ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [], standardInput: input
        ))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.standardOutput, input)
    }

    func testChildClosingStandardInputEarlyDoesNotTerminateTheApp() async throws {
        let result = try await ProcessRunner().run(ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
            standardInput: Data(repeating: 0x61, count: 2_000_000)
        ))
        XCTAssertTrue(result.succeeded)
    }

    func testCancellationStopsChildIgnoringTerminationWhileInputIsBlocked() async throws {
        let ready = FileManager.default.temporaryDirectory.appendingPathComponent("SvnDock-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ready) }
        let task = Task {
            try await ProcessRunner().run(ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; printf ready > \"$1\"; exec /bin/sleep 6", "svndock-test", ready.path],
                standardInput: Data(repeating: 0x61, count: 2_000_000)
            ))
        }
        defer { task.cancel() }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }
}
