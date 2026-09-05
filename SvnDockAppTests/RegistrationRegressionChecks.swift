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
