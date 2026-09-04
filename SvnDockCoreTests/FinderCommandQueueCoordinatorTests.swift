import Foundation
import XCTest
@testable import SvnDockCore

final class FinderCommandQueueCoordinatorTests: XCTestCase {
    func testTwoCoordinatorsCompetingForSameCommandProduceExactlyOneClaim() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = makeCommand()
        try await enqueue(command, in: directory)

        let applicationCoordinator = try FinderCommandQueueCoordinator(directoryURL: directory)
        let agentCoordinator = try FinderCommandQueueCoordinator(directoryURL: directory)

        async let applicationResult = applicationCoordinator.claimCommand(
            id: command.id,
            as: .application
        )
        async let agentResult = agentCoordinator.claimCommand(id: command.id, as: .agent)
        let (applicationClaim, agentClaim) = try await (applicationResult, agentResult)
        let winners = [applicationClaim, agentClaim].compactMap { $0 }

        XCTAssertEqual(winners.count, 1)
        let winner = try XCTUnwrap(winners.first)
        XCTAssertEqual(winner.command, command)
        let location = try await applicationCoordinator.location(of: command.id)
        XCTAssertEqual(location, .processing(owner: winner.owner, phase: .claimed))
        let secondApplicationClaim = try await applicationCoordinator.claimCommand(
            id: command.id,
            as: .application
        )
        let secondAgentClaim = try await agentCoordinator.claimCommand(
            id: command.id,
            as: .agent
        )
        XCTAssertNil(secondApplicationClaim)
        XCTAssertNil(secondAgentClaim)
    }

    func testDuplicatePhysicalFilesForOneIDStillProduceOneOwnerAndOneReceipt() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = makeCommand()
        try await enqueue(command, in: directory)
        let applicationCoordinator = try FinderCommandQueueCoordinator(directoryURL: directory)
        let agentCoordinator = try FinderCommandQueueCoordinator(directoryURL: directory)
        try await applicationCoordinator.prepareDirectories()

        let fileName = command.id.uuidString.lowercased() + ".json"
        try FileManager.default.copyItem(
            at: directory.appendingPathComponent("command-queue/").appendingPathComponent(fileName),
            to: directory.appendingPathComponent("command-app-inbox/").appendingPathComponent(fileName)
        )

        async let applicationResult = applicationCoordinator.claimCommand(
            id: command.id,
            as: .application
        )
        async let agentResult = agentCoordinator.claimCommand(id: command.id, as: .agent)
        let (applicationClaim, agentClaim) = try await (applicationResult, agentResult)
        let winners = [applicationClaim, agentClaim].compactMap { $0 }
        XCTAssertEqual(winners.count, 1)

        let winner = try XCTUnwrap(winners.first)
        let executing: FinderCommandClaim
        if winner.owner == .application {
            executing = try await applicationCoordinator.markExecuting(winner)
            try await applicationCoordinator.acknowledge(executing, outcome: .completed)
        } else {
            executing = try await agentCoordinator.markExecuting(winner)
            try await agentCoordinator.acknowledge(executing, outcome: .completed)
        }

        let applicationIDs = try await applicationCoordinator.availableCommandIDs(
            for: .application
        )
        let agentIDs = try await agentCoordinator.availableCommandIDs(for: .agent)
        let location = try await applicationCoordinator.location(of: command.id)
        XCTAssertTrue(applicationIDs.isEmpty)
        XCTAssertTrue(agentIDs.isEmpty)
        XCTAssertEqual(location, .completed(.completed))
    }

    func testAgentHandoffAtomicallyPublishesCommandOnlyToApplicationInbox() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = makeCommand(kind: .commit)
        try await enqueue(command, in: directory)

        let agentCoordinator = try FinderCommandQueueCoordinator(directoryURL: directory)
        let applicationCoordinator = try FinderCommandQueueCoordinator(directoryURL: directory)
        let claimed = try await agentCoordinator.claimCommand(id: command.id, as: .agent)
        let agentClaim = try XCTUnwrap(claimed)

        try await agentCoordinator.handoffToApplication(agentClaim)

        let handedOffLocation = try await applicationCoordinator.location(of: command.id)
        XCTAssertEqual(handedOffLocation, .applicationInbox)
        XCTAssertTrue(
            try fileNames(in: directory.appendingPathComponent("command-processing/agent")).isEmpty
        )
        XCTAssertEqual(
            try fileNames(in: directory.appendingPathComponent("command-app-inbox")),
            ["\(command.id.uuidString.lowercased()).json"]
        )
        let agentReclaim = try await agentCoordinator.claimCommand(id: command.id, as: .agent)
        XCTAssertNil(agentReclaim)

        do {
            try await agentCoordinator.acknowledge(agentClaim, outcome: .cancelled)
            XCTFail("The Agent claim must become stale immediately after handoff")
        } catch let error as FinderCommandQueueError {
            guard case .staleClaim = error else {
                return XCTFail("Expected staleClaim, got \(error)")
            }
        }

        let appResult = try await applicationCoordinator.claimCommand(
            id: command.id,
            as: .application
        )
        let applicationClaim = try XCTUnwrap(appResult)
        XCTAssertEqual(applicationClaim.owner, .application)
        XCTAssertEqual(applicationClaim.command, command)
        XCTAssertNotEqual(applicationClaim.token, agentClaim.token)
        try await applicationCoordinator.acknowledge(applicationClaim, outcome: .cancelled)
        let cancelledLocation = try await applicationCoordinator.location(of: command.id)
        XCTAssertEqual(cancelledLocation, .completed(.cancelled))
    }

    func testAgentHandoffCollapsesIdenticalInboxCopyCreatedAfterClaim() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = makeCommand(kind: .commit)
        try await enqueue(command, in: directory)
        let agentCoordinator = try FinderCommandQueueCoordinator(directoryURL: directory)
        let applicationCoordinator = try FinderCommandQueueCoordinator(directoryURL: directory)
        let claimResult = try await agentCoordinator.claimCommand(
            id: command.id,
            as: .agent
        )
        let claim = try XCTUnwrap(claimResult)

        let processingDirectory = directory.appendingPathComponent(
            "command-processing/agent",
            isDirectory: true
        )
        let processingURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: processingDirectory,
                includingPropertiesForKeys: nil
            ).first
        )
        let inboxURL = directory
            .appendingPathComponent("command-app-inbox", isDirectory: true)
            .appendingPathComponent("\(command.id.uuidString.lowercased()).json")
        try FileManager.default.copyItem(at: processingURL, to: inboxURL)

        try await agentCoordinator.handoffToApplication(claim)

        XCTAssertTrue(try fileNames(in: processingDirectory).isEmpty)
        let handedOffLocation = try await applicationCoordinator.location(of: command.id)
        XCTAssertEqual(handedOffLocation, .applicationInbox)
        let appClaimResult = try await applicationCoordinator.claimCommand(
            id: command.id,
            as: .application
        )
        let appClaim = try XCTUnwrap(appClaimResult)
        XCTAssertEqual(appClaim.command, command)
        try await applicationCoordinator.acknowledge(appClaim, outcome: .cancelled)
        let completedLocation = try await applicationCoordinator.location(of: command.id)
        XCTAssertEqual(completedLocation, .completed(.cancelled))
    }

    func testAgentHandoffAtomicallyQuarantinesConflictingInboxCopy() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = makeCommand(kind: .commit)
        try await enqueue(command, in: directory)
        let coordinator = try FinderCommandQueueCoordinator(directoryURL: directory)
        let claimResult = try await coordinator.claimCommand(id: command.id, as: .agent)
        let claim = try XCTUnwrap(claimResult)

        let conflicting = makeCommand(kind: .revert, id: command.id)
        try await enqueue(conflicting, in: directory)
        let fileName = command.id.uuidString.lowercased() + ".json"
        try FileManager.default.moveItem(
            at: directory
                .appendingPathComponent("command-queue", isDirectory: true)
                .appendingPathComponent(fileName),
            to: directory
                .appendingPathComponent("command-app-inbox", isDirectory: true)
                .appendingPathComponent(fileName)
        )

        let disposition = try await coordinator.handoffToApplication(claim)

        let location = try await coordinator.location(of: command.id)
        let appClaim = try await coordinator.claimCommand(id: command.id, as: .application)
        XCTAssertEqual(disposition, .quarantinedConflict)
        XCTAssertEqual(location, .uncertain)
        XCTAssertNil(appClaim)
        XCTAssertTrue(
            try fileNames(in: directory.appendingPathComponent("command-processing/agent")).isEmpty
        )
    }

    func testRecoveryQuarantinesAgentClaimWhenConflictingInboxAppearedBeforeHandoff() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = makeCommand(kind: .commit)
        try await enqueue(command, in: directory)
        let coordinator = try FinderCommandQueueCoordinator(directoryURL: directory)
        let claimResult = try await coordinator.claimCommand(id: command.id, as: .agent)
        _ = try XCTUnwrap(claimResult)

        let conflicting = makeCommand(kind: .revert, id: command.id)
        try await enqueue(conflicting, in: directory)
        let fileName = command.id.uuidString.lowercased() + ".json"
        try FileManager.default.moveItem(
            at: directory
                .appendingPathComponent("command-queue", isDirectory: true)
                .appendingPathComponent(fileName),
            to: directory
                .appendingPathComponent("command-app-inbox", isDirectory: true)
                .appendingPathComponent(fileName)
        )
        let leaseResult = try await coordinator.acquireConsumerLease(for: .agent)
        let lease = try XCTUnwrap(leaseResult)

        let summary = try await coordinator.recoverOrphanedClaims(
            for: .agent,
            lease: lease
        )

        let location = try await coordinator.location(of: command.id)
        XCTAssertEqual(summary, FinderCommandRecoverySummary(quarantined: 1))
        XCTAssertEqual(location, .uncertain)
        XCTAssertTrue(
            try fileNames(in: directory.appendingPathComponent("command-processing/agent")).isEmpty
        )
        withExtendedLifetime(lease) {}
    }

    func testReleaseCollapsesIdenticalPendingCopyWithoutLosingRequest() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = makeCommand(kind: .update)
        try await enqueue(command, in: directory)
        let coordinator = try FinderCommandQueueCoordinator(directoryURL: directory)
        let claimResult = try await coordinator.claimCommand(id: command.id, as: .agent)
        let claim = try XCTUnwrap(claimResult)
        try await enqueue(command, in: directory)

        let disposition = try await coordinator.releaseWithoutExecution(claim)

        XCTAssertEqual(disposition, .collapsedIdenticalDuplicate)
        let releasedLocation = try await coordinator.location(of: command.id)
        XCTAssertEqual(releasedLocation, .pending)
        let replacementResult = try await coordinator.claimCommand(id: command.id, as: .agent)
        let replacement = try XCTUnwrap(replacementResult)
        let executing = try await coordinator.markExecuting(replacement)
        try await coordinator.acknowledge(executing, outcome: .completed)
        let completedLocation = try await coordinator.location(of: command.id)
        XCTAssertEqual(completedLocation, .completed(.completed))
    }

    func testReleaseQuarantinesConflictingPendingCopyAndLocationFailsClosed() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = makeCommand(kind: .update)
        try await enqueue(command, in: directory)
        let coordinator = try FinderCommandQueueCoordinator(directoryURL: directory)
        let claimResult = try await coordinator.claimCommand(id: command.id, as: .agent)
        let claim = try XCTUnwrap(claimResult)
        let conflicting = makeCommand(kind: .cleanup, id: command.id)
        try await enqueue(conflicting, in: directory)

        let disposition = try await coordinator.releaseWithoutExecution(claim)

        XCTAssertEqual(disposition, .quarantinedConflict)
        let location = try await coordinator.location(of: command.id)
        let agentClaim = try await coordinator.claimCommand(id: command.id, as: .agent)
        let applicationClaim = try await coordinator.claimCommand(
            id: command.id,
            as: .application
        )
        XCTAssertEqual(location, .uncertain)
        XCTAssertNil(agentClaim)
        XCTAssertNil(applicationClaim)
    }

    func testConflictingUnownedCopiesAreQuarantinedBeforeApplicationClaim() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = makeCommand(kind: .commit)
        try await enqueue(command, in: directory)
        let coordinator = try FinderCommandQueueCoordinator(directoryURL: directory)
        try await coordinator.prepareDirectories()

        let stagingDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let conflicting = makeCommand(kind: .revert, id: command.id)
        let stagingStore = try FinderSharedStore(directoryURL: stagingDirectory)
        let stagedURL = try await stagingStore.enqueue(conflicting)
        let fileName = command.id.uuidString.lowercased() + ".json"
        try FileManager.default.copyItem(
            at: stagedURL,
            to: directory
                .appendingPathComponent("command-app-inbox", isDirectory: true)
                .appendingPathComponent(fileName)
        )

        do {
            _ = try await coordinator.claimCommand(id: command.id, as: .application)
            XCTFail("Expected conflicting physical copies to fail closed")
        } catch let error as FinderCommandQueueError {
            guard case .conflictingCommandCopies(let id) = error,
                  id == command.id else {
                return XCTFail("Expected conflictingCommandCopies, got \(error)")
            }
        }

        let location = try await coordinator.location(of: command.id)
        XCTAssertEqual(location, .uncertain)
        XCTAssertTrue(try fileNames(in: directory.appendingPathComponent("command-queue")).isEmpty)
        XCTAssertTrue(
            try fileNames(in: directory.appendingPathComponent("command-app-inbox")).isEmpty
        )
    }

    func testReleasedOldClaimCannotAcknowledgeAReplacementClaim() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = makeCommand()
        try await enqueue(command, in: directory)
        let coordinator = try FinderCommandQueueCoordinator(directoryURL: directory)

        let firstResult = try await coordinator.claimCommand(id: command.id, as: .agent)
        let firstClaim = try XCTUnwrap(firstResult)
        try await coordinator.releaseWithoutExecution(firstClaim)
        let secondResult = try await coordinator.claimCommand(id: command.id, as: .agent)
        let secondClaim = try XCTUnwrap(secondResult)
        XCTAssertNotEqual(firstClaim.token, secondClaim.token)

        do {
            try await coordinator.acknowledge(firstClaim, outcome: .cancelled)
            XCTFail("A stale token must not be able to acknowledge the replacement claim")
        } catch let error as FinderCommandQueueError {
            guard case .staleClaim = error else {
                return XCTFail("Expected staleClaim, got \(error)")
            }
        }

        let replacementLocation = try await coordinator.location(of: command.id)
        XCTAssertEqual(replacementLocation, .processing(owner: .agent, phase: .claimed))
        let executingSecondClaim = try await coordinator.markExecuting(secondClaim)
        try await coordinator.acknowledge(executingSecondClaim, outcome: .completed)
        let completedLocation = try await coordinator.location(of: command.id)
        XCTAssertEqual(completedLocation, .completed(.completed))
    }

    func testRecoveryReleasesClaimedAndAwaitingUserApplicationClaims() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let claimedCommand = makeCommand(kind: .diff)
        let awaitingCommand = makeCommand(kind: .revert)
        try await enqueue(claimedCommand, in: directory)
        try await enqueue(awaitingCommand, in: directory)
        let coordinator = try FinderCommandQueueCoordinator(directoryURL: directory)

        let firstResult = try await coordinator.claimCommand(
            id: claimedCommand.id,
            as: .application
        )
        _ = try XCTUnwrap(firstResult)
        let secondResult = try await coordinator.claimCommand(
            id: awaitingCommand.id,
            as: .application
        )
        let secondClaim = try XCTUnwrap(secondResult)
        _ = try await coordinator.markAwaitingUser(secondClaim)
        let leaseResult = try await coordinator.acquireConsumerLease(for: .application)
        let lease = try XCTUnwrap(leaseResult)

        let summary = try await coordinator.recoverOrphanedClaims(
            for: .application,
            lease: lease
        )

        XCTAssertEqual(summary, FinderCommandRecoverySummary(released: 2))
        let claimedLocation = try await coordinator.location(of: claimedCommand.id)
        let awaitingLocation = try await coordinator.location(of: awaitingCommand.id)
        let applicationIDs = try await coordinator.availableCommandIDs(for: .application)
        let agentIDs = try await coordinator.availableCommandIDs(for: .agent)
        XCTAssertEqual(claimedLocation, .applicationInbox)
        XCTAssertEqual(awaitingLocation, .applicationInbox)
        XCTAssertEqual(Set(applicationIDs), Set([claimedCommand.id, awaitingCommand.id]))
        XCTAssertTrue(agentIDs.isEmpty)
        withExtendedLifetime(lease) {}
    }

    func testRecoveryQuarantinesExecutingClaimWithoutRequeueingIt() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = makeCommand(kind: .update)
        try await enqueue(command, in: directory)
        let coordinator = try FinderCommandQueueCoordinator(directoryURL: directory)
        let claimResult = try await coordinator.claimCommand(id: command.id, as: .agent)
        let claim = try XCTUnwrap(claimResult)
        _ = try await coordinator.markExecuting(claim)
        let leaseResult = try await coordinator.acquireConsumerLease(for: .agent)
        let lease = try XCTUnwrap(leaseResult)

        let summary = try await coordinator.recoverOrphanedClaims(for: .agent, lease: lease)

        XCTAssertEqual(summary, FinderCommandRecoverySummary(quarantined: 1))
        let location = try await coordinator.location(of: command.id)
        let agentIDs = try await coordinator.availableCommandIDs(for: .agent)
        let applicationIDs = try await coordinator.availableCommandIDs(for: .application)
        let reclaimed = try await coordinator.claimCommand(id: command.id, as: .agent)
        let secondRecovery = try await coordinator.recoverOrphanedClaims(
            for: .agent,
            lease: lease
        )
        XCTAssertEqual(location, .uncertain)
        XCTAssertTrue(agentIDs.isEmpty)
        XCTAssertTrue(applicationIDs.isEmpty)
        XCTAssertNil(reclaimed)
        XCTAssertEqual(secondRecovery, FinderCommandRecoverySummary())
        withExtendedLifetime(lease) {}
    }

    func testAcknowledgeLeavesDurableReceiptAndRemovesProcessingClaim() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = makeCommand(kind: .cleanup)
        try await enqueue(command, in: directory)
        let coordinator = try FinderCommandQueueCoordinator(directoryURL: directory)
        let claimResult = try await coordinator.claimCommand(id: command.id, as: .agent)
        let claim = try XCTUnwrap(claimResult)
        let executing = try await coordinator.markExecuting(claim)

        try await coordinator.acknowledge(executing, outcome: .completed)

        let completedLocation = try await coordinator.location(of: command.id)
        XCTAssertEqual(completedLocation, .completed(.completed))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory
                    .appendingPathComponent("command-receipts")
                    .appendingPathComponent("\(command.id.uuidString.lowercased()).json")
                    .path
            )
        )
        XCTAssertTrue(
            try fileNames(in: directory.appendingPathComponent("command-processing/agent")).isEmpty
        )
        let duplicateClaim = try await coordinator.claimCommand(id: command.id, as: .agent)
        XCTAssertNil(duplicateClaim)
    }

    func testRecoveryCleansClaimWhenReceiptWasWrittenBeforeClaimRemovalFailed() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = makeCommand(kind: .cleanup)
        try await enqueue(command, in: directory)
        let failingFileManager = ClaimRemovalFailingFileManager()
        let interruptedCoordinator = try FinderCommandQueueCoordinator(
            directoryURL: directory,
            fileManager: failingFileManager
        )
        let claimResult = try await interruptedCoordinator.claimCommand(
            id: command.id,
            as: .agent
        )
        let claim = try XCTUnwrap(claimResult)
        let executing = try await interruptedCoordinator.markExecuting(claim)

        do {
            try await interruptedCoordinator.acknowledge(executing, outcome: .completed)
            XCTFail("The injected processing-file removal must fail")
        } catch let error as FinderCommandQueueError {
            guard case .filesystemFailure = error else {
                return XCTFail("Expected filesystemFailure, got \(error)")
            }
        }

        let receiptURL = directory
            .appendingPathComponent("command-receipts")
            .appendingPathComponent("\(command.id.uuidString.lowercased()).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL.path))
        XCTAssertEqual(
            try fileNames(in: directory.appendingPathComponent("command-processing/agent")).count,
            1
        )
        let exactReceipt = try await interruptedCoordinator.hasMatchingReceipt(
            for: executing,
            outcome: .completed
        )
        let wrongOutcomeReceipt = try await interruptedCoordinator.hasMatchingReceipt(
            for: executing,
            outcome: .rejected
        )
        XCTAssertTrue(exactReceipt)
        XCTAssertFalse(wrongOutcomeReceipt)

        let recoveringCoordinator = try FinderCommandQueueCoordinator(directoryURL: directory)
        let leaseResult = try await recoveringCoordinator.acquireConsumerLease(for: .agent)
        let lease = try XCTUnwrap(leaseResult)
        let summary = try await recoveringCoordinator.recoverOrphanedClaims(
            for: .agent,
            lease: lease
        )

        XCTAssertEqual(summary, FinderCommandRecoverySummary(completedCleanup: 1))
        XCTAssertTrue(
            try fileNames(in: directory.appendingPathComponent("command-processing/agent")).isEmpty
        )
        let recoveredLocation = try await recoveringCoordinator.location(of: command.id)
        XCTAssertEqual(recoveredLocation, .completed(.completed))
        withExtendedLifetime(lease) {}
    }

    func testConsumerLeaseIsSingletonPerDirectoryAndConsumer() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstCoordinator = try FinderCommandQueueCoordinator(directoryURL: directory)
        let secondCoordinator = try FinderCommandQueueCoordinator(directoryURL: directory)

        var firstLease = try await firstCoordinator.acquireConsumerLease(for: .application)
        XCTAssertNotNil(firstLease)
        let duplicateApplicationLease = try await secondCoordinator.acquireConsumerLease(
            for: .application
        )
        XCTAssertNil(duplicateApplicationLease)

        let independentAgentLease = try await secondCoordinator.acquireConsumerLease(for: .agent)
        XCTAssertNotNil(independentAgentLease)

        weak var releasedLease = firstLease
        firstLease = nil
        XCTAssertNil(releasedLease)
        let replacementLease = try await secondCoordinator.acquireConsumerLease(for: .application)
        XCTAssertNotNil(replacementLease)
        withExtendedLifetime(independentAgentLease) {}
        withExtendedLifetime(replacementLease) {}
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SvnDockQueueCoordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeCommand(
        kind: FinderCommandKind = .update,
        id: UUID = UUID()
    ) -> FinderCommand {
        FinderCommand(
            id: id,
            kind: kind,
            paths: ["/tmp/svndock-test-working-copy/file.txt"],
            workingCopyRoot: "/tmp/svndock-test-working-copy",
            createdAt: Date(timeIntervalSince1970: 1_788_486_123),
            source: "finder-extension"
        )
    }

    private func enqueue(_ command: FinderCommand, in directory: URL) async throws {
        let store = try FinderSharedStore(directoryURL: directory)
        _ = try await store.enqueue(command)
    }

    private func fileNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).map(\.lastPathComponent).sorted()
    }
}

private final class ClaimRemovalFailingFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        if URL.path.contains("/command-processing/") {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}
