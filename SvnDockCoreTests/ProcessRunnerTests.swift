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
}
