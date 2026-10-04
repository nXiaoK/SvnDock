#if SVNDOCK_SMOKE_TESTS
import Foundation
import SvnDockCore

enum FinderQueueRegressionSmoke {
    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SvnDockQueueRegression-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FinderSharedStore(directoryURL: directory)
        let coordinator = try FinderCommandQueueCoordinator(directoryURL: directory)
        try await coordinator.prepareDirectories()
        let command = FinderCommand(
            kind: .update, paths: ["/tmp/working-copy"], workingCopyRoot: "/tmp/working-copy"
        )
        let pending = try await store.enqueue(command)
        let inbox = directory.appendingPathComponent("command-app-inbox")
            .appendingPathComponent(pending.lastPathComponent)
        try FileManager.default.copyItem(at: pending, to: inbox)
        guard let claim = try await coordinator.claimCommand(id: command.id, as: .application) else {
            throw Failure("Expected a command claim")
        }
        let executing = try await coordinator.markExecuting(claim)
        try await coordinator.acknowledge(executing, outcome: .completed)
        try check(!FileManager.default.fileExists(atPath: pending.path), "completed pending duplicate removed")
        try check(!FileManager.default.fileExists(atPath: inbox.path), "completed inbox duplicate removed")

        _ = try await store.enqueue(command)
        let completedIDs = try await coordinator.availableCommandIDs(for: .agent)
        try check(completedIDs.isEmpty, "completed duplicate cannot execute again")
        try check(!FileManager.default.fileExists(atPath: pending.path), "late completed duplicate removed")

        let conflicting = FinderCommand(
            id: command.id, kind: .cleanup, paths: command.paths,
            workingCopyRoot: command.workingCopyRoot, createdAt: command.createdAt
        )
        _ = try await store.enqueue(conflicting)
        _ = try await coordinator.availableCommandIDs(for: .agent)
        let uncertain = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("command-uncertain"), includingPropertiesForKeys: nil
        )
        try check(uncertain.count == 1, "conflicting completed copy preserved for inspection")
        try check(!FileManager.default.fileExists(atPath: pending.path), "conflict leaves the hot queue")
        let location = try await coordinator.location(of: command.id)
        try check(location == .completed(.completed), "original receipt remains authoritative")

        let blocked = FinderCommand(kind: .update, paths: command.paths, workingCopyRoot: command.workingCopyRoot)
        let available = FinderCommand(kind: .update, paths: command.paths, workingCopyRoot: command.workingCopyRoot)
        _ = try await store.enqueue(blocked)
        _ = try await store.enqueue(available)
        try Data("{".utf8).write(
            to: directory.appendingPathComponent("command-receipts")
                .appendingPathComponent(blocked.id.uuidString.lowercased() + ".json"),
            options: .atomic
        )
        let availableIDs = try await coordinator.availableCommandIDs(for: .agent)
        try check(availableIDs == [available.id], "malformed receipt only blocks its own command")
        try await checkRecoveryWithUnreadableReceipts()
        print("Passed Finder queue regression checks, including unreadable receipt recovery")
    }

    private static func checkRecoveryWithUnreadableReceipts() async throws {
        for owner in [FinderCommandConsumer.application, .agent] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("SvnDockReceiptRecovery-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try FinderSharedStore(directoryURL: directory)
            let coordinator = try FinderCommandQueueCoordinator(directoryURL: directory)
            guard let lease = try await coordinator.acquireConsumerLease(for: owner) else {
                throw Failure("Expected recovery lease")
            }
            var receiptFiles: [(URL, Data)] = []
            for phase in [FinderCommandClaimPhase.claimed, .awaitingUser, .executing] {
                for incompatible in [false, true] {
                    let command = FinderCommand(kind: .update, paths: ["/tmp/working-copy"], workingCopyRoot: "/tmp/working-copy")
                    _ = try await store.enqueue(command)
                    guard var claim = try await coordinator.claimCommand(id: command.id, as: owner) else {
                        throw Failure("Expected recovery fixture claim")
                    }
                    if phase == .awaitingUser { claim = try await coordinator.markAwaitingUser(claim) }
                    if phase == .executing { claim = try await coordinator.markExecuting(claim) }
                    let data: Data
                    if incompatible {
                        let encoder = JSONEncoder()
                        encoder.dateEncodingStrategy = .iso8601
                        data = try encoder.encode(FinderCommandReceipt(schemaVersion: FinderSharedSchema.currentVersion + 1,
                            command: command, owner: owner, claimToken: claim.token, outcome: .completed))
                    } else { data = Data("{".utf8) }
                    let receipt = directory.appendingPathComponent("command-receipts")
                        .appendingPathComponent(command.id.uuidString.lowercased() + ".json")
                    try data.write(to: receipt, options: .atomic)
                    receiptFiles.append((receipt, data))
                    _ = try await store.enqueue(command)
                }
            }
            let available = FinderCommand(kind: .update, paths: ["/tmp/working-copy"], workingCopyRoot: "/tmp/working-copy")
            _ = try await store.enqueue(available)
            guard try await coordinator.claimCommand(id: available.id, as: owner) != nil else {
                throw Failure("Expected unrelated orphan claim")
            }
            let recovered = try await coordinator.recoverOrphanedClaims(for: owner, lease: lease)
            try check(recovered == FinderCommandRecoverySummary(released: 1, quarantined: 6),
                      "bad receipts isolate every orphan phase while unrelated claims recover")
            let ids = try await coordinator.availableCommandIDs(for: owner)
            try check(ids == [available.id], "same-UUID pending duplicates cannot replay after bad receipt recovery")
            let uncertain = try FileManager.default.contentsOfDirectory(
                at: directory.appendingPathComponent("command-uncertain"), includingPropertiesForKeys: nil)
            try check(uncertain.count == 6, "all affected claims remain available for inspection")
            for (url, data) in receiptFiles {
                try check(try Data(contentsOf: url) == data, "unreadable terminal records remain intact as deduplication barriers")
            }
            guard let claim = try await coordinator.claimCommand(id: available.id, as: owner) else {
                throw Failure("Unrelated recovered command must remain executable")
            }
            let executing = try await coordinator.markExecuting(claim)
            try await coordinator.acknowledge(executing, outcome: .completed)
            let repeated = try await coordinator.recoverOrphanedClaims(for: owner, lease: lease)
            try check(repeated == FinderCommandRecoverySummary(), "recovery does not reprocess quarantined claims")
            withExtendedLifetime(lease) {}
        }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
#endif
