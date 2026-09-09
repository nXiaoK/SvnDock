import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum FileRestoreRegressionChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(description: message) }
    }

    @MainActor
    static func run() async throws {
        for input in ["", "0", "-1", "r-1", "1:2", "HEAD", String(Int.max) + "0"] {
            try check(SvnDockFileRestorePlan.parseRevision(input) == nil, "invalid revision: \(input)")
        }
        try check(SvnDockFileRestorePlan.parseRevision(" r2 ") == 2, "r-prefixed revision")
        try check(SvnDockFileRestorePlan.parseRevision(String(Int.max)) == Int.max, "bounded subtraction")
        guard let executable = SVNExecutableLocator.defaultCandidatePaths.map({ URL(fileURLWithPath: $0) })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path)
                && FileManager.default.isExecutableFile(atPath: $0.deletingLastPathComponent().appendingPathComponent("svnadmin").path) }) else {
            throw Failure(description: "File restore integration requires SVN and svnadmin")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("file-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repository = temporary.appendingPathComponent("repo")
        let root = temporary.appendingPathComponent("wc")
        let config = temporary.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data("[miscellany]\nenable-auto-props = no\nglobal-ignores =\n".utf8).write(to: config.appendingPathComponent("config"))
        let runner = FileRestoreRunner(config: config)
        let created = try await ProcessRunner().run(.init(executableURL: executable.deletingLastPathComponent().appendingPathComponent("svnadmin"), arguments: ["create", repository.path]))
        try check(created.succeeded, "create temporary repository")
        @discardableResult
        func svn(_ args: [String]) async throws -> ProcessResult {
            let result = try await runner.run(.init(executableURL: executable, arguments: args,
                currentDirectoryURL: FileManager.default.fileExists(atPath: root.path) ? root : temporary))
            try check(result.succeeded, "fixture command \(args): \(result.standardErrorString)")
            return result
        }
        try await svn(["checkout", repository.absoluteString, root.path])
        let name = "-文件 @ # %.txt"
        let file = root.appendingPathComponent(name)
        let sibling = root.appendingPathComponent("sibling.txt")
        let binary = root.appendingPathComponent("binary.bin")
        let oldBinary = Data([0, 255, 1, 2, 13, 10])
        try Data("old\n".utf8).write(to: file)
        try Data("sibling\n".utf8).write(to: sibling)
        try oldBinary.write(to: binary)
        try await svn(["add", "--", name + "@", "sibling.txt", "binary.bin"])
        try await svn(["propset", "custom:state", "old property", "--", name + "@"])
        try await svn(["propset", "svn:mime-type", "application/octet-stream", "binary.bin"])
        try await svn(["commit", "-m", "Seed files"])
        try Data("new\n".utf8).write(to: file)
        try Data([0, 3, 4, 255]).write(to: binary)
        try await svn(["propset", "custom:state", "new property", "--", name + "@"])
        try await svn(["commit", "-m", "Change content and properties"])
        try await svn(["update"])
        let shared = try FinderSharedStore(directoryURL: temporary.appendingPathComponent("shared"))
        let service = try CoreSvnDockService(sharedStore: shared,
            executableLocator: SVNExecutableLocator(candidatePaths: [executable.path]), processRunner: runner)
        let copy = try await service.registerWorkingCopy(at: root)
        let plan = try await service.prepareFileRestore(relativePath: name, beforeRevision: 2, in: copy)
        try check(plan.targetRevision == 1 && plan.baseRevision == 2, "before r2 means r1")
        try check(try Data(contentsOf: file) == Data("new\n".utf8), "preview never changes files")
        try Data("unrelated edit\n".utf8).write(to: sibling)
        try await service.restoreFile(plan)
        try check(try Data(contentsOf: file) == Data("old\n".utf8), "restore literal Unicode and @ filename")
        let prop = try await svn(["propget", "--strict", "custom:state", "--", name + "@"])
        try check(prop.standardOutputString == "old property", "restore versioned properties")
        try check(try Data(contentsOf: sibling) == Data("unrelated edit\n".utf8), "preserve unselected edits")
        let info = try await svn(["info", "--show-item", "revision", "--", name + "@"])
        try check(info.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines) == "2", "BASE stays at r2 for a future commit")
        let properties = try await svn(["proplist", "--", name + "@"])
        try check(!properties.standardOutputString.contains("svn:mergeinfo"), "restore does not add merge tracking")
        try await svn(["revert", "--", name + "@"])
        let binaryPlan = try await service.prepareFileRestore(relativePath: "binary.bin", beforeRevision: 2, in: copy)
        try await service.restoreFile(binaryPlan)
        try check(try Data(contentsOf: binary) == oldBinary, "binary bytes restored exactly")
        try await svn(["revert", "binary.bin"])

        // A preview cannot authorize discarding a later edit or property change.
        try Data("keep local edit\n".utf8).write(to: file)
        do { try await service.restoreFile(plan); throw Failure(description: "accepted stale local edit") }
        catch is SvnDockServiceError { }
        try check(try Data(contentsOf: file) == Data("keep local edit\n".utf8), "stale plan preserves local edits")
        try await svn(["revert", "--", name + "@"])
        try await svn(["propset", "custom:local", "keep", "--", name + "@"])
        do { try await service.restoreFile(plan); throw Failure(description: "accepted local property edit") }
        catch is SvnDockServiceError { }
        try await svn(["revert", "--", name + "@"])
        for revision in [0, -1, Int.min, 1, 4] {
            do {
                _ = try await service.prepareFileRestore(relativePath: name, beforeRevision: revision, in: copy)
                throw Failure(description: "accepted nonexistent or invalid revision \(revision)")
            } catch is SvnDockServiceError { }
        }
        do {
            _ = try await service.prepareFileRestore(relativePath: ".", beforeRevision: 2, in: copy)
            throw Failure(description: "accepted directory")
        } catch is SvnDockServiceError { }
        let link = root.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        do {
            _ = try await service.prepareFileRestore(relativePath: "alias.txt", beforeRevision: 2, in: copy)
            throw Failure(description: "accepted symlink")
        } catch is SvnDockServiceError { }

        // Follow the selected node's ancestry across a committed rename.
        try await svn(["move", "--", name + "@", "renamed.txt"])
        try await svn(["commit", "-m", "Rename file", "--", name + "@", "renamed.txt"])
        try await svn(["update"])
        let movedPlan = try await service.prepareFileRestore(relativePath: "renamed.txt", beforeRevision: 2, in: copy)
        try check(movedPlan.historicalURL.lastPathComponent == name, "historical info follows rename ancestry")
        try await service.restoreFile(movedPlan)
        try check(try Data(contentsOf: root.appendingPathComponent("renamed.txt")) == Data("old\n".utf8), "restore follows old path but keeps local name")
        try await svn(["revert", "renamed.txt"])

        // Finder routing uses one captured file and holds later queue items until cancellation/confirmation.
        let store = SvnDockStore(service: service, finderSharedStore: shared)
        try check(await store.load(), "restore store loads")
        store.requestFileRestoreImporter(for: copy)
        try check(store.isInteractionBlocked, "file picker captures and gates its working copy")
        await store.completeFileImport(.success([copy.rootURL.appendingPathComponent("renamed.txt")]), requestID: store.fileImportRequest!.id)
        try check(store.pendingFileRestore?.entry.relativePath == "renamed.txt" && store.isPresentingFileRestore,
                  "in-app file selection opens history restore for a clean file absent from the status list")
        store.cancelFileRestore()
        store.requestFileRestoreImporter(for: copy)
        await store.completeFileImport(.success([]), requestID: store.fileImportRequest!.id)
        try check(!store.isInteractionBlocked, "cancelling file selection releases the interaction gate")
        let command = FinderCommand(kind: .restoreBeforeRevision,
            paths: [copy.rootURL.appendingPathComponent("renamed.txt").path], workingCopyRoot: copy.rootURL.path)
        try await shared.enqueue(command)
        let url = URL(string: "svndock://finder-command?request=\(command.id.uuidString)")!
        await store.handleFinderURL(url)
        try check(store.isPresentingFileRestore && store.pendingFileRestore?.entry.relativePath == "renamed.txt",
                  "Finder opens a revision sheet for a clean file absent from sparse status")
        let duplicate = Task { await store.handleFinderURL(url) }
        let request = store.pendingFileRestore!
        let confirmed = try await store.prepareFileRestore(requestID: request.id, beforeRevision: 2)
        store.selectedEntryIDs = []
        store.confirmFileRestore(confirmed, requestID: request.id)
        try check(store.activeOperation != nil && !store.isPresentingFileRestore, "confirm publishes busy state synchronously")
        try await waitUntil { store.activeOperation == nil }
        try check(store.operationRecords.first?.outcome == .success, "restore records verified success")
        try check(try Data(contentsOf: root.appendingPathComponent("renamed.txt")) == Data("old\n".utf8), "confirmation retains file scope after selection changes")
        await duplicate.value
        let coordinator = try FinderCommandQueueCoordinator(directoryURL: shared.directoryURL)
        try check(try await coordinator.location(of: command.id) == .completed(.completed), "Finder restore acknowledged once")
        try await svn(["revert", "renamed.txt"])
        let cancel = FinderCommand(kind: .restoreBeforeRevision,
            paths: command.paths, workingCopyRoot: copy.rootURL.path)
        try await shared.enqueue(cancel)
        await store.handleFinderURL(URL(string: "svndock://finder-command?request=\(cancel.id.uuidString)")!)
        store.cancelFileRestore()
        try await waitUntil { try await coordinator.location(of: cancel.id) == .completed(.cancelled) }
        try check(try Data(contentsOf: root.appendingPathComponent("renamed.txt")) == Data("new\n".utf8), "cancelled restore leaves content unchanged")
        print("File restore checks passed: rN-1, content/properties, binary, literal paths, rename ancestry, stale edits, invalid targets and Finder confirmation receipts")
    }

    @MainActor
    private static func waitUntil(_ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while try await !condition() {
            guard ContinuousClock.now < deadline else { throw Failure(description: "restore operation timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor FileRestoreRunner: ProcessRunning {
    let config: URL
    init(config: URL) { self.config = config }
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        try await ProcessRunner().run(.init(executableURL: invocation.executableURL,
            arguments: ["--config-dir", config.path, "--no-auth-cache"] + invocation.arguments,
            currentDirectoryURL: invocation.currentDirectoryURL, environment: invocation.environment,
            standardInput: invocation.standardInput,
            argumentFiles: invocation.argumentFiles.map { .init(argumentIndex: $0.argumentIndex + 3, contents: $0.contents) }))
    }
}
