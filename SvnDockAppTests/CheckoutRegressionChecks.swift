import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum CheckoutRegressionChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(description: message) }
    }

    @MainActor
    static func run() async throws {
        for value in ["", "/tmp/repo", "ftp://example.com/repo", "https://", "https://user:secret@example.com/repo", "https://example.com/repo?q=1", "https://example.com/repo#fragment"] {
            do { _ = try SVNCheckout.repositoryURL(from: value); throw Failure(description: "accepted invalid repository URL") }
            catch is SVNCheckoutError { }
        }
        guard let executable = SVNExecutableLocator.defaultCandidatePaths.map({ URL(fileURLWithPath: $0) }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
                && FileManager.default.isExecutableFile(atPath: $0.deletingLastPathComponent().appendingPathComponent("svnadmin").path)
        }) else { throw Failure(description: "Checkout integration requires SVN and svnadmin") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("checkout-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repository = temporary.appendingPathComponent("repo @ 中文")
        let seed = temporary.appendingPathComponent("seed")
        let runner = CheckoutFixtureRunner(configuration: temporary.appendingPathComponent("svn-config"))
        try await runner.prepareConfiguration()
        let admin = try await ProcessRunner().run(.init(executableURL: executable.deletingLastPathComponent().appendingPathComponent("svnadmin"), arguments: ["create", repository.path]))
        try check(admin.succeeded, "create checkout fixture repository")
        func svn(_ arguments: [String], in directory: URL) async throws -> ProcessResult {
            let result = try await runner.run(.init(executableURL: executable, arguments: arguments, currentDirectoryURL: directory))
            try check(result.succeeded, "fixture SVN: \(result.standardErrorString)")
            return result
        }
        _ = try await svn(["checkout", "--", repository.absoluteString + "@HEAD", seed.path], in: temporary)
        let name = "-文件 @.txt"
        try Data("old\n".utf8).write(to: seed.appendingPathComponent(name))
        let bytes = Data([0, 1, 255, 3, 0])
        try bytes.write(to: seed.appendingPathComponent("binary.bin"))
        _ = try await svn(["add", "--", name + "@", "binary.bin"], in: seed)
        _ = try await svn(["propset", "custom:test", "preserved", "--", name + "@"], in: seed)
        _ = try await svn(["commit", "-m", "Seed checkout"], in: seed)
        try Data("latest\n".utf8).write(to: seed.appendingPathComponent(name))
        _ = try await svn(["commit", "-m", "Latest checkout revision"], in: seed)
        let shared = try FinderSharedStore(directoryURL: temporary.appendingPathComponent("shared"))
        let service = try CoreSvnDockService(sharedStore: shared,
            executableLocator: SVNExecutableLocator(candidatePaths: [executable.path]), processRunner: runner)
        let destination = temporary.appendingPathComponent("new @ 项目")
        let reports = CheckoutReports()
        let request = try SvnDockCheckoutRequest(repositoryAddress: repository.absoluteString, localPath: destination.path)
        let copy = try await service.checkout(request, progress: { reports.append($0) })
        try check(copy.rootURL.resolvingSymlinksInPath().path == destination.path && copy.repositoryUUID != nil && copy.revision == 2,
                  "checkout metadata: root=\(copy.rootURL.path), expected=\(destination.path), revision=\(String(describing: copy.revision)), uuid=\(String(describing: copy.repositoryUUID))")
        try check(try Data(contentsOf: destination.appendingPathComponent(name)) == Data("latest\n".utf8)
                    && Data(contentsOf: destination.appendingPathComponent("binary.bin")) == bytes,
                  "checkout preserves latest text and binary bytes")
        let property = try await svn(["propget", "--strict", "custom:test", "--", name + "@"], in: destination)
        try check(property.standardOutputString == "preserved", "versioned properties survive publishing")
        let roots = try await shared.loadRegisteredRoots()
        try check(roots.roots.contains { $0.id == copy.id && $0.path == destination.path }, "successful checkout is registered automatically")
        try check(reports.values.contains { $0.processedItemCount >= 2 }
                    && !reports.values.contains { $0.currentPath?.contains(".svndock-checkout-") == true },
                  "progress reports real paths without exposing staging directories")

        let empty = temporary.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o750])
        _ = try await service.checkout(.init(repositoryAddress: repository.absoluteString, localPath: empty.path), progress: { _ in })
        let permissions = try FileManager.default.attributesOfItem(atPath: empty.path)[.posixPermissions] as? NSNumber
        try check(permissions?.intValue == 0o750, "checkout preserves an existing empty directory's permissions")
        let sentinel = destination.appendingPathComponent("sentinel.txt")
        try Data("keep".utf8).write(to: sentinel)
        do { _ = try await service.checkout(request, progress: { _ in }); throw Failure(description: "overwrote nonempty destination") }
        catch is SVNCheckoutError { }
        try check(try Data(contentsOf: sentinel) == Data("keep".utf8), "existing local files remain unchanged")
        let link = temporary.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: empty)
        do {
            _ = try await service.checkout(.init(repositoryAddress: repository.absoluteString, localPath: link.path), progress: { _ in })
            throw Failure(description: "accepted symlink destination")
        } catch is SVNCheckoutError { }
        let failedPath = temporary.appendingPathComponent("failed")
        do {
            _ = try await service.checkout(.init(repositoryAddress: repository.appendingPathComponent("absent").absoluteString, localPath: failedPath.path), progress: { _ in })
            throw Failure(description: "accepted missing repository path")
        } catch is SVNCheckoutError { }
        try check(!FileManager.default.fileExists(atPath: failedPath.path), "failed checkout leaves no partial destination")

        let raced = temporary.appendingPathComponent("raced")
        await runner.setMode(.race(raced))
        do {
            _ = try await service.checkout(.init(repositoryAddress: repository.absoluteString, localPath: raced.path), progress: { _ in })
            throw Failure(description: "overwrote a destination created during checkout")
        } catch is SVNCheckoutError { }
        try check(try Data(contentsOf: raced.appendingPathComponent("sentinel")) == Data("keep".utf8), "publication never overwrites a raced destination")
        await runner.setMode(.normal)

        let store = SvnDockStore(service: service)
        try check(await store.load(), "checkout store loads")
        store.requestCheckout()
        store.beginCheckout(repositoryAddress: "not a URL", localPath: failedPath.path)
        try check(!store.isCheckingOut && store.checkoutError != nil && store.isPresentingCheckout,
                  "invalid input stays editable without starting an operation")
        store.beginCheckout(repositoryAddress: repository.absoluteString, localPath: destination.path)
        try check(store.isCheckingOut, "checkout publishes busy state synchronously")
        try await waitUntil { !store.isCheckingOut }
        try check(store.checkoutError != nil && store.isPresentingCheckout, "failure preserves the checkout form for retry")
        let retry = temporary.appendingPathComponent("retry")
        store.beginCheckout(repositoryAddress: repository.absoluteString, localPath: retry.path)
        try await waitUntil { !store.isCheckingOut }
        try check(!store.isPresentingCheckout && !store.isInteractionBlocked && store.selectedWorkingCopy?.rootURL.path == retry.path,
                  "successful retry selects the newly registered copy and closes the form")
        try check(store.operationRecords.first?.outcome == .success && store.transferProgress.snapshot == nil,
                  "checkout records success after verification and clears transfer progress")

        await runner.setMode(.cancel)
        let cancelled = temporary.appendingPathComponent("cancelled")
        store.requestCheckout()
        store.beginCheckout(repositoryAddress: repository.absoluteString, localPath: cancelled.path)
        try await waitUntil { await runner.isWaitingForCancellation }
        store.cancelCheckout()
        try await waitUntil { !store.isCheckingOut }
        try check(store.checkoutError?.contains("取消") == true && !FileManager.default.fileExists(atPath: cancelled.path),
                  "cancellation terminates the download and removes partial content")
        store.dismissCheckout()
        try check(!store.isInteractionBlocked && store.transferProgress.snapshot == nil, "cancellation releases UI and progress state")
        let files = try FileManager.default.contentsOfDirectory(atPath: temporary.path)
        try check(!files.contains { $0.hasPrefix(".svndock-checkout-") }, "success, failure and cancellation leave no staging directories")
        print("Checkout checks passed: HEAD, text/binary/properties, automatic registration, empty/nonempty paths, race protection, progress, cancellation and retry")
    }

    @MainActor
    private static func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw Failure(description: "checkout operation timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class CheckoutReports: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [SVNProgressSnapshot] = []
    var values: [SVNProgressSnapshot] { lock.withLock { reports } }
    func append(_ report: SVNProgressSnapshot) { lock.withLock { reports.append(report) } }
}

private actor CheckoutFixtureRunner: ProcessRunning {
    enum Mode: Sendable { case normal, race(URL), cancel }
    let configuration: URL
    private var mode = Mode.normal
    private(set) var isWaitingForCancellation = false
    init(configuration: URL) { self.configuration = configuration }
    func setMode(_ value: Mode) { mode = value }
    func prepareConfiguration() throws {
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: false)
        try Data("[miscellany]\nenable-auto-props = no\nglobal-ignores =\n".utf8).write(to: configuration.appendingPathComponent("config"))
    }
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        try await run(invocation, onOutput: { _ in })
    }
    func run(_ invocation: ProcessInvocation, onOutput: @escaping @Sendable (ProcessOutputChunk) -> Void) async throws -> ProcessResult {
        if invocation.arguments.first == "checkout", case .cancel = mode {
            let stage = URL(fileURLWithPath: invocation.arguments.last!)
            try Data("partial".utf8).write(to: stage.appendingPathComponent("partial"))
            isWaitingForCancellation = true
            defer { isWaitingForCancellation = false }
            while true { try await Task.sleep(for: .milliseconds(10)) }
        }
        if invocation.arguments.first == "info", case .race(let destination) = mode {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try Data("keep".utf8).write(to: destination.appendingPathComponent("sentinel"))
        }
        return try await ProcessRunner().run(.init(executableURL: invocation.executableURL,
            arguments: ["--config-dir", configuration.path, "--no-auth-cache"] + invocation.arguments,
            currentDirectoryURL: invocation.currentDirectoryURL, environment: invocation.environment,
            standardInput: invocation.standardInput,
            argumentFiles: invocation.argumentFiles.map { .init(argumentIndex: $0.argumentIndex + 3, contents: $0.contents) }), onOutput: onOutput)
    }
}
