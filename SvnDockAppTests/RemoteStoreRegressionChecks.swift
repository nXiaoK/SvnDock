import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum RemoteStoreRegressionChecks {
    @MainActor
    static func run() async throws {
        try await productionRemoteStatusMapping()
        let service = RemoteStatusFixtureService()
        let store = SvnDockStore(service: service)
        try check(await store.load(), "the fixture working copies load")
        let copies = store.workingCopies
        try check(copies.count == 2, "both fixture copies remain registered")
        let first = copies[0]
        let second = copies[1]
        let initialRemoteCalls = await service.remoteCalls
        try check(initialRemoteCalls == 0, "loading local status never contacts the repository")

        await store.reloadSelectedWorkingCopy()
        let reloadRemoteCalls = await service.remoteCalls
        try check(reloadRemoteCalls == 0, "refreshing local status never checks for remote updates")
        try check(store.selectedWorkingCopy?.revision == 9
                    && store.selectedWorkingCopy?.repositoryURL?.path == "/repo/trunk",
                  "local refresh republishes refreshed root baseline and repository metadata")

        await store.checkSelectedRemoteStatus()
        let originalSnapshot = store.selectedRemoteStatus.snapshot
        try check(originalSnapshot?.entries.map(\.relativePath) == ["incoming.txt"],
                  "an explicit check publishes incoming-only files independently from local status")
        try check(store.entries.isEmpty && store.statusCounts == .zero,
                  "incoming changes cannot become local modifications or committable files")

        await service.failNextCheck()
        await store.checkSelectedRemoteStatus()
        try check(store.selectedRemoteStatus.snapshot == originalSnapshot
                    && store.selectedRemoteStatus.isStale
                    && store.selectedRemoteStatus.lastError != nil
                    && !store.selectedRemoteStatus.isChecking,
                  "a failed check preserves the earlier entries and check time with a stale marker")

        await store.checkSelectedRemoteStatus()
        try check(store.selectedRemoteStatus.lastError == nil && !store.selectedRemoteStatus.isStale,
                  "a successful retry replaces an error and refreshes its result")
        await store.reloadSelectedWorkingCopy()
        try check(store.selectedRemoteStatus.isStale && store.selectedRemoteStatus.snapshot != nil,
                  "local refresh invalidates, but retains, an earlier server result")

        await service.holdNextCheck()
        let firstCheck = Task { await store.checkSelectedRemoteStatus() }
        try await waitUntil { await service.hasPendingCheck }
        try check(store.selectedRemoteStatus.isChecking, "a pending request is visibly checking")
        store.selectedWorkingCopyID = second.id
        try check(store.selectedRemoteStatus.snapshot == nil && !store.selectedRemoteStatus.isChecking,
                  "switching copies cannot display the other copy's snapshot or checking state")
        await service.finishPendingCheck()
        await firstCheck.value
        try check(store.selectedRemoteStatus.snapshot == nil,
                  "a late result belongs to its original working copy")

        await store.checkSelectedRemoteStatus()
        try check(store.selectedRemoteStatus.snapshot?.entries.isEmpty == true,
                  "the second working copy publishes its independent clean remote result")
        store.selectedWorkingCopyID = first.id
        try check(store.selectedRemoteStatus.snapshot?.entries.map(\.relativePath) == ["incoming.txt"]
                    && !store.selectedRemoteStatus.isChecking,
                  "returning to a working copy restores only its own completed result")
    }

    private static func productionRemoteStatusMapping() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("svndock-remote-status-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("wc", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let shared = try FinderSharedStore(directoryURL: temporary.appendingPathComponent("shared"))
        let runner = RemoteStatusXMLFixtureRunner(root: root)
        let service = try CoreSvnDockService(sharedStore: shared,
            executableLocator: SVNExecutableLocator(candidatePaths: ["/usr/bin/true"]),
            processRunner: runner)
        let copy = try await service.registerWorkingCopy(at: root)
        let local = try await service.status(for: copy)
        try check(local.entries.count == 1 && local.entries.first?.relativePath == "local.txt",
                  "the production local status path keeps local changes")
        let badgeURL = shared.directoryURL.appendingPathComponent(FinderSharedSchema.badgeSnapshotFileName)
        let originalBadges = try Data(contentsOf: badgeURL)
        let remote = try await service.checkRemoteStatus(for: copy)
        try check(remote.entries.count == 2,
                  "the production remote check retains incoming-only text and property-only changes")
        try check(remote.entries.first { $0.relativePath == "incoming.txt" }?.status == .modified,
                  "a locally normal file with a remote content change remains visible")
        try check(remote.entries.first { $0.relativePath == "." }?.propertiesChanged == true,
                  "a remote-only directory property change survives XML parsing and UI mapping")
        try check(!remote.entries.contains { $0.relativePath == "local.txt" },
                  "a local-only modification cannot become an incoming change")
        let checkedBadges = try Data(contentsOf: badgeURL)
        try check(checkedBadges == originalBadges,
                  "checking the server never replaces the local Finder badge snapshot")
        let statusArguments = await runner.statusArguments
        try check(statusArguments.count == 2
                    && !statusArguments[0].contains("--show-updates")
                    && statusArguments[1].contains("--show-updates"),
                  "only the explicit production remote check enables SVN server status")
        await runner.advanceRevision()
        let refreshed = try await service.refreshWorkingCopyMetadata(for: copy)
        try check(refreshed.revision == 43 && refreshed.repositoryURL?.path == "/repo/branches/release",
                  "production metadata refresh reads the updated root revision and URL")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw RemoteStatusFixtureFailure(message: message) }
    }

    @MainActor
    private static func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard clock.now < deadline else { throw RemoteStatusFixtureFailure(message: "fixture operation timed out") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private struct RemoteStatusFixtureFailure: Error { let message: String }

private actor RemoteStatusXMLFixtureRunner: ProcessRunning {
    let root: URL
    private var revision = 42
    private(set) var statusArguments: [[String]] = []

    init(root: URL) { self.root = root }
    func advanceRevision() { revision = 43 }

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        let xml: String
        switch invocation.arguments.first {
        case "status":
            statusArguments.append(invocation.arguments)
            let remoteEntries = invocation.arguments.contains("--show-updates") ? """
                <entry path="incoming.txt"><wc-status item="normal" props="none" revision="42"/><repos-status item="modified" props="none"/></entry>
                <entry path="."><wc-status item="normal" props="normal" revision="42"/><repos-status item="none" props="modified"/></entry>
                """ : ""
            xml = """
                <status><target path=".">
                <entry path="local.txt"><wc-status item="modified" props="none" revision="42"/></entry>
                \(remoteEntries)
                </target></status>
                """
        case "info":
            xml = """
                <info><entry path="." kind="dir" revision="\(revision)">
                <url>https://example.test/repo/\(revision == 42 ? "trunk" : "branches/release")</url>
                <repository><root>https://example.test/repo</root><uuid>fixture</uuid></repository>
                <wc-info><wcroot-abspath>\(root.path)</wcroot-abspath><schedule>normal</schedule></wc-info>
                </entry></info>
                """
        default:
            throw RemoteStatusFixtureFailure(message: "unexpected fixture command")
        }
        return ProcessResult(terminationStatus: 0, terminationReason: .exit,
                             standardOutput: Data(xml.utf8), standardError: Data())
    }
}

private actor RemoteStatusFixtureService: SvnDockServicing {
    private let first = SvnDockWorkingCopy(name: "Alpha", rootURL: URL(fileURLWithPath: "/fixture/alpha"), revision: 1)
    private let second = SvnDockWorkingCopy(name: "Beta", rootURL: URL(fileURLWithPath: "/fixture/beta"), revision: 2)
    private var shouldFail = false
    private var shouldHold = false
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var remoteCalls = 0

    var hasPendingCheck: Bool { pending != nil }
    func failNextCheck() { shouldFail = true }
    func holdNextCheck() { shouldHold = true }
    func finishPendingCheck() { pending?.resume(); pending = nil }
    func loadRegisteredWorkingCopies() async throws -> [SvnDockWorkingCopy] { [first, second] }
    func status(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockStatusSnapshot { .empty }
    func refreshWorkingCopyMetadata(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockWorkingCopy {
        var updated = workingCopy
        updated.revision = 9
        updated.repositoryURL = URL(string: "https://example.test/repo/trunk")
        return updated
    }
    func checkRemoteStatus(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockRemoteStatusSnapshot {
        remoteCalls += 1
        if shouldFail {
            shouldFail = false
            throw unavailable
        }
        if shouldHold {
            shouldHold = false
            await withCheckedContinuation { pending = $0 }
        }
        return .init(entries: workingCopy.id == first.id
            ? [.init(relativePath: "incoming.txt", status: .modified)] : [],
            checkedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(remoteCalls)))
    }
    func registerWorkingCopy(at url: URL) async throws -> SvnDockWorkingCopy { throw unavailable }
    func unregisterWorkingCopy(id: UUID) async throws { throw unavailable }
    func directoryChildren(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> [SvnDockStatusEntry] { [] }
    func diff(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> String { throw unavailable }
    func history(for workingCopy: SvnDockWorkingCopy, relativePaths: [String], limit: Int) async throws -> [SvnDockLogEntry] { [] }
    func revisionDetails(revision: Int, in workingCopy: SvnDockWorkingCopy) async throws -> SVNRevisionDetails { throw unavailable }
    func revisionDiff(revision: Int, change: SVNChangedPath, repositoryRoot: URL, in workingCopy: SvnDockWorkingCopy) async throws -> String { throw unavailable }
    func update(workingCopies: [SvnDockWorkingCopy]) async throws { throw unavailable }
    func commit(workingCopy: SvnDockWorkingCopy, relativePaths: [String], message: String) async throws { throw unavailable }
    func add(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func unscheduleAdd(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func cleanupMissingAdditions(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func scheduleMissingDeletion(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func revert(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func resolve(relativePaths: [String], using resolution: SvnDockConflictResolution, in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func addIgnoreRules(_ rules: [SvnDockIgnoreRule], in workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    func cleanup(workingCopy: SvnDockWorkingCopy) async throws { throw unavailable }
    private var unavailable: SvnDockServiceError { .unavailable("Fixture server is unavailable") }
}
