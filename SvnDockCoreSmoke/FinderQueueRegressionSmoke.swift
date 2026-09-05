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
        print("Passed 4 Finder queue regression checks")
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
