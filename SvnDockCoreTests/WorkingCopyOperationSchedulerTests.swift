import Foundation
import XCTest
@testable import SvnDockCore

final class WorkingCopyOperationSchedulerTests: XCTestCase {
    func testOperationsForSameWorkingCopyNeverOverlap() async throws {
        let scheduler = WorkingCopyOperationScheduler()
        let probe = SchedulerConcurrencyProbe()
        let workingCopyID = UUID()

        let tasks = (0..<8).map { _ in
            Task {
                try await scheduler.enqueue(for: workingCopyID) {
                    await probe.perform(for: workingCopyID)
                }
            }
        }

        for task in tasks {
            try await task.value
        }

        let maximum = await probe.maximum(for: workingCopyID)
        let remainingCount = await scheduler.scheduledWorkingCopyCount
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(remainingCount, 0)
    }

    func testDifferentWorkingCopiesCanOverlap() async throws {
        let scheduler = WorkingCopyOperationScheduler()
        let probe = SchedulerConcurrencyProbe()
        let firstID = UUID()
        let secondID = UUID()

        async let first: Void = scheduler.enqueue(for: firstID) {
            await probe.perform(for: firstID)
        }
        async let second: Void = scheduler.enqueue(for: secondID) {
            await probe.perform(for: secondID)
        }
        _ = try await (first, second)

        let globalMaximum = await probe.globalMaximum
        let firstMaximum = await probe.maximum(for: firstID)
        let secondMaximum = await probe.maximum(for: secondID)
        XCTAssertGreaterThanOrEqual(globalMaximum, 2)
        XCTAssertEqual(firstMaximum, 1)
        XCTAssertEqual(secondMaximum, 1)
    }

    func testSVNOperationOverloadUsesWorkingCopyIdentity() async throws {
        let scheduler = WorkingCopyOperationScheduler()
        let operation = SVNOperation(workingCopyID: UUID(), kind: .cleanup)

        let value = try await scheduler.enqueue(operation) { received in
            received.kind == .cleanup ? "done" : "wrong"
        }

        XCTAssertEqual(value, "done")
    }
}

private actor SchedulerConcurrencyProbe {
    private var activeByWorkingCopy: [UUID: Int] = [:]
    private var maximumByWorkingCopy: [UUID: Int] = [:]
    private var globalActive = 0
    private(set) var globalMaximum = 0

    func perform(for workingCopyID: UUID) async {
        activeByWorkingCopy[workingCopyID, default: 0] += 1
        maximumByWorkingCopy[workingCopyID] = max(
            maximumByWorkingCopy[workingCopyID, default: 0],
            activeByWorkingCopy[workingCopyID, default: 0]
        )
        globalActive += 1
        globalMaximum = max(globalMaximum, globalActive)

        try? await Task.sleep(nanoseconds: 40_000_000)

        activeByWorkingCopy[workingCopyID, default: 0] -= 1
        globalActive -= 1
    }

    func maximum(for workingCopyID: UUID) -> Int {
        maximumByWorkingCopy[workingCopyID, default: 0]
    }
}
