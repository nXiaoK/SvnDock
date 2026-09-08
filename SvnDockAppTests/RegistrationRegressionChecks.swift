import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum RegistrationRegressionChecks {
    static func run() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("svndock-registration-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("wc", isDirectory: true)
        let shared = try FinderSharedStore(directoryURL: temporary.appendingPathComponent("shared"))
        let runner = RegistrationInfoRunner(root: root)
        let service = try CoreSvnDockService(
            sharedStore: shared,
            executableLocator: SVNExecutableLocator(candidatePaths: ["/usr/bin/true"]),
            processRunner: runner
        )
        let copy = try await service.registerWorkingCopy(at: root.appendingPathComponent("child"))
        try check(copy.rootURL == root, "registration resolves the WC root")
        try check(copy.repositoryURL?.absoluteString == "https://svn.example.test/repo/trunk",
                  "registration reads repository URL from root info")
        try check(copy.revision == 12, "registration reads revision from root info")
        let calls = await runner.directories
        try check(calls == [root.appendingPathComponent("child"), root], "subdirectory registration reloads only root info")
        let again = try await service.registerWorkingCopy(at: root)
        try check(again.id == copy.id, "root registration preserves identity")
        try await trailingWhitespaceIntegration()
    }

    private static func trailingWhitespaceIntegration() async throws {
        guard let executable = SVNExecutableLocator.defaultCandidatePaths
            .map({ URL(fileURLWithPath: $0) })
            .first(where: {
                FileManager.default.isExecutableFile(atPath: $0.path)
                    && FileManager.default.isExecutableFile(
                        atPath: $0.deletingLastPathComponent().appendingPathComponent("svnadmin").path
                    )
            }) else {
            print("SKIP whitespace registration integration: SVN and svnadmin are unavailable")
            return
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("svndock-registration-whitespace-\(UUID())", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repository = temporary.appendingPathComponent("repository", isDirectory: true)
        let root = temporary.appendingPathComponent("wc ", isDirectory: true)
        let sibling = temporary.appendingPathComponent("wc", isDirectory: true)
        let runner = RegistrationSVNRunner(configuration: temporary.appendingPathComponent("svn-config"))
        let created = try await ProcessRunner().run(ProcessInvocation(
            executableURL: executable.deletingLastPathComponent().appendingPathComponent("svnadmin"),
            arguments: ["create", repository.path]
        ))
        try check(created.succeeded, "create disposable registration repository")
        func svn(_ arguments: [String]) async throws {
            let result = try await runner.run(ProcessInvocation(
                executableURL: executable, arguments: arguments, currentDirectoryURL: temporary
            ))
            try check(result.succeeded, "registration fixture SVN failed: \(result.standardErrorString)")
        }
        let selectedRepositoryURL = repository.appendingPathComponent("selected")
        let siblingRepositoryURL = repository.appendingPathComponent("sibling")
        try await svn(["mkdir", selectedRepositoryURL.absoluteString, siblingRepositoryURL.absoluteString,
                       "-m", "Create distinct registration roots"])
        try await svn(["checkout", selectedRepositoryURL.absoluteString, root.path])
        try await svn(["checkout", siblingRepositoryURL.absoluteString, sibling.path])
        let shared = try FinderSharedStore(directoryURL: temporary.appendingPathComponent("shared"))
        let service = try CoreSvnDockService(
            sharedStore: shared,
            executableLocator: SVNExecutableLocator(candidatePaths: [executable.path],
                                                     environmentOverrideKey: "SVNDOCK_REGISTRATION_TEST_UNUSED"),
            processRunner: runner
        )
        let siblingCopy = try await service.registerWorkingCopy(at: sibling)
        let selectedCopy = try await service.registerWorkingCopy(at: root)
        try check(selectedCopy.rootURL.path == root.path,
                  "registration must preserve a trailing-space root when its trimmed sibling exists")
        try check(selectedCopy.id != siblingCopy.id,
                  "distinct working-copy paths must retain distinct registration identities")
        try check(selectedCopy.repositoryURL == selectedRepositoryURL,
                  "registration must retain the selected root's repository metadata")
        let registered = try await shared.loadRegisteredRoots()
        try check(Set(registered.roots.map(\.path)) == Set([root.path, sibling.path]),
                  "persisted registration must retain both exact working-copy paths")
        try FileManager.default.removeItem(at: sibling)
        let again = try await service.registerWorkingCopy(at: root)
        try check(again.id == selectedCopy.id && again.rootURL.path == root.path,
                  "whitespace registration must also succeed without a trimmed sibling")
        print("Registration integration passed: distinct trailing-space roots and repository metadata")
    }

    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw RegistrationFailure(message: message) }
    }
}

private actor RegistrationInfoRunner: ProcessRunning {
    let root: URL
    var directories: [URL] = []
    init(root: URL) { self.root = root }
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        let directory = invocation.currentDirectoryURL!
        directories.append(directory)
        let isRoot = directory == root
        let xml = """
        <info><entry path="." kind="dir" revision="\(isRoot ? 12 : 7)">
        <url>https://svn.example.test/repo/trunk\(isRoot ? "" : "/child")</url>
        <repository><root>https://svn.example.test/repo</root><uuid>fixture</uuid></repository>
        <wc-info><wcroot-abspath>\(root.path)</wcroot-abspath><schedule>normal</schedule></wc-info>
        </entry></info>
        """
        return ProcessResult(terminationStatus: 0, terminationReason: .exit,
                             standardOutput: Data(xml.utf8), standardError: Data())
    }
}

private struct RegistrationFailure: Error { let message: String }

private struct RegistrationSVNRunner: ProcessRunning {
    let configuration: URL

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        try await ProcessRunner().run(ProcessInvocation(
            executableURL: invocation.executableURL,
            arguments: ["--config-dir", configuration.path, "--no-auth-cache", "--non-interactive"] + invocation.arguments,
            currentDirectoryURL: invocation.currentDirectoryURL,
            environment: invocation.environment,
            standardInput: invocation.standardInput,
            argumentFiles: invocation.argumentFiles.map {
                ProcessArgumentFile(argumentIndex: $0.argumentIndex + 4, contents: $0.contents)
            }
        ))
    }
}
