import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum ResolveServiceRegressionChecks {
    @discardableResult
    static func run() async throws -> Bool {
        try await verificationResultsAndBoundaries()
        guard let executable = SVNExecutableLocator.defaultCandidatePaths.map({ URL(fileURLWithPath: $0) })
            .first(where: {
                FileManager.default.isExecutableFile(atPath: $0.path)
                    && FileManager.default.isExecutableFile(atPath: $0.deletingLastPathComponent().appendingPathComponent("svnadmin").path)
            }) else {
            print("SKIP resolve service integration: SVN and svnadmin are unavailable")
            return false
        }
        try await realConflictChecks(executable: executable)
        print("Resolve service checks passed: post-command verification, text/property conflicts, selected scope and WC boundaries")
        return true
    }

    private static func verificationResultsAndBoundaries() async throws {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("wc", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        for name in ["text.txt", "sibling.txt"] { try Data("local content".utf8).write(to: root.appendingPathComponent(name)) }
        let copy = SvnDockWorkingCopy(name: "resolve fixture", rootURL: root)
        for outcome in ResolveVerificationFixtureRunner.Outcome.allCases {
            let textFile = root.appendingPathComponent("text.txt")
            try FileManager.default.removeItem(at: textFile)
            if outcome == .inRootSymlink {
                try FileManager.default.createSymbolicLink(at: textFile, withDestinationURL: root.appendingPathComponent("sibling.txt"))
            } else {
                try Data("local content".utf8).write(to: textFile)
            }
            let runner = ResolveVerificationFixtureRunner(root: root, outcome: outcome)
            let service = try service(root: temporary.appendingPathComponent(UUID().uuidString), executable: URL(fileURLWithPath: "/usr/bin/true"), runner: runner)
            do {
                let choice: SvnDockConflictResolution = outcome == .inRootSymlink || outcome == .symlinkAfterInfo ? .mineFull : .working
                try await service.resolve(relativePaths: ["text.txt"], using: choice, in: copy)
                try check(outcome == .successWithSiblingConflict, "only verified selected targets report resolve success")
            } catch let error as SvnDockResolveVerificationError {
                switch outcome {
                case .remainingText, .remainingProperty, .remainingTree:
                    try check(error == .remainingConflicts(paths: ["text.txt"]), "all conflict kinds are checked after resolving")
                case .failedStatus, .malformedStatus, .cancelledStatus:
                    guard case .statusUnavailable = error else { throw ResolveCheckFailure(message: "post-read failure needs a verification error") }
                    try check(error.localizedDescription.contains("命令已执行") && error.localizedDescription.contains("软件未自动重试"),
                              "verification errors explain that the mutation already ran")
                default: throw error
                }
            } catch SvnDockServiceError.unavailable {
                try check(outcome == .fileExternal || outcome == .differentWorkingCopy
                          || outcome == .inRootSymlink || outcome == .symlinkAfterInfo,
                          "invalid WC boundaries and nonregular replacement targets fail before mutation")
            }
            let invocations = await runner.invocations
            let resolveCommands = invocations.filter { $0.arguments.first == "resolve" }
            let shouldMutate = outcome != .fileExternal && outcome != .differentWorkingCopy
                && outcome != .inRootSymlink && outcome != .symlinkAfterInfo
            try check(resolveCommands.count == (shouldMutate ? 1 : 0), "failed verification never repeats a mutation")
            if shouldMutate {
                try check(invocations.map { $0.arguments.first! } == ["status", "info", "resolve", "status"],
                          "selected resolve is preceded by preflight and followed by one verification read")
                try check(resolveCommands[0].arguments.contains("--depth") && resolveCommands[0].arguments.contains("empty"),
                          "directory conflict resolution explicitly stays shallow")
            } else if outcome == .symlinkAfterInfo {
                try check(invocations.map { $0.arguments.first! } == ["status", "info"],
                          "a target replaced by an in-root symlink after preflight cannot reach resolve")
            }
        }
        let outside = temporary.appendingPathComponent("outside.txt")
        try Data("outside content".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escaped"), withDestinationURL: outside)
        let runner = ResolveVerificationFixtureRunner(root: root, outcome: .successWithSiblingConflict)
        let boundaryService = try service(root: temporary.appendingPathComponent("boundary-state"), executable: URL(fileURLWithPath: "/usr/bin/true"), runner: runner)
        do {
            try await boundaryService.resolve(relativePaths: ["escaped"], using: .working, in: copy)
            throw ResolveCheckFailure(message: "symlink outside WC must be rejected")
        } catch SvnDockServiceError.unavailable { }
        try check(await runner.invocations.isEmpty, "symlink boundary rejection launches no SVN command")
    }

    private static func realConflictChecks(executable: URL) async throws {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repository = temporary.appendingPathComponent("repository", isDirectory: true)
        let root = temporary.appendingPathComponent("wc", isDirectory: true)
        let peer = temporary.appendingPathComponent("peer", isDirectory: true)
        let runner = ResolveIntegrationRunner(configuration: temporary.appendingPathComponent("svn-config", isDirectory: true))
        let created = try await ProcessRunner().run(ProcessInvocation(
            executableURL: executable.deletingLastPathComponent().appendingPathComponent("svnadmin"), arguments: ["create", repository.path]
        ))
        try check(created.succeeded, "create disposable resolve repository")
        func svn(_ arguments: [String], directory: URL? = nil) async throws -> ProcessResult {
            let result = try await runner.run(ProcessInvocation(executableURL: executable, arguments: arguments, currentDirectoryURL: directory ?? root))
            try check(result.succeeded, "resolve fixture SVN failed: \(result.standardErrorString)")
            return result
        }
        _ = try await svn(["checkout", repository.absoluteString, root.path], directory: temporary)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("properties"), withIntermediateDirectories: false)
        let files = ["selected@文本.txt", "sibling.txt", "properties/child.txt"]
        for path in files { try Data("base\n".utf8).write(to: root.appendingPathComponent(path)) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("tree-victim.txt"))
        _ = try await svn(["add", "--", files[0] + "@", files[1], "properties", "tree-victim.txt"])
        _ = try await svn(["propset", "fixture:setting", "base", "properties"])
        _ = try await svn(["commit", "-m", "Seed resolve fixture", "--", "."])
        _ = try await svn(["checkout", repository.absoluteString, peer.path])
        for path in files {
            try Data("local\n".utf8).write(to: root.appendingPathComponent(path))
            try Data("server\n".utf8).write(to: peer.appendingPathComponent(path))
        }
        _ = try await svn(["delete", "--", "tree-victim.txt"])
        try Data("server tree edit\n".utf8).write(to: peer.appendingPathComponent("tree-victim.txt"))
        _ = try await svn(["propset", "fixture:setting", "local", "properties"])
        _ = try await svn(["propset", "fixture:setting", "server", "properties"], directory: peer)
        _ = try await svn(["commit", "-m", "Create incoming text and property changes", "--", "."], directory: peer)
        _ = try await svn(["update", "--accept", "postpone", "--", "."])
        func status() async throws -> [StatusEntry] {
            let result = try await svn(["status", "--xml"])
            return try SVNXMLParser.parseStatus(result.standardOutput, workingCopyURL: root)
        }
        let conflicted = try await status()
        try check(conflicted.filter { $0.status == .conflicted }.count == 3
                  && conflicted.contains { $0.path == "properties" && $0.propertyStatus == .conflicted },
                  "real fixture has three text conflicts and a directory property conflict")
        try check(conflicted.contains { $0.path == "tree-victim.txt" && $0.isTreeConflicted },
                  "locally deleted incoming edit creates a real missing-file tree conflict")
        let service = try service(root: temporary.appendingPathComponent("app-state"), executable: executable, runner: runner)
        let copy = SvnDockWorkingCopy(name: "resolve fixture", rootURL: root)
        try await service.resolve(relativePaths: [files[0]], using: .mineFull, in: copy)
        let afterText = try await status()
        try check(!afterText.contains { $0.path == files[0] && $0.status == .conflicted }
                  && afterText.contains { $0.path == "sibling.txt" && $0.status == .conflicted },
                  "resolving a selected text file leaves the unselected sibling conflict")
        try check(try String(contentsOf: root.appendingPathComponent(files[0]), encoding: .utf8) == "local\n",
                  "the requested mine-full resolution retains the local version")
        try await service.resolve(relativePaths: ["properties"], using: .working, in: copy)
        let afterProperty = try await status()
        try check(!afterProperty.contains { $0.path == "properties" && $0.propertyStatus == .conflicted }
                  && afterProperty.contains { $0.path == "properties/child.txt" && $0.status == .conflicted }
                  && afterProperty.contains { $0.path == "sibling.txt" && $0.status == .conflicted },
                  "resolving directory properties preserves unselected child and sibling conflicts")
        try await service.resolve(relativePaths: ["tree-victim.txt"], using: .working, in: copy)
        let afterTree = try await status()
        try check(!afterTree.contains { $0.path == "tree-victim.txt" && $0.isTreeConflicted }
                  && afterTree.contains { $0.path == "sibling.txt" && $0.status == .conflicted },
                  "missing-file tree conflicts can be verified and resolved without clearing siblings")
        try check(await runner.resolveCount == 3, "each user-selected resolution mutates exactly once")
    }

    private static func service(root: URL, executable: URL, runner: any ProcessRunning) throws -> CoreSvnDockService {
        try CoreSvnDockService(
            sharedStore: FinderSharedStore(directoryURL: root),
            executableLocator: SVNExecutableLocator(candidatePaths: [executable.path], environmentOverrideKey: "SVNDOCK_RESOLVE_TEST_UNUSED"),
            processRunner: runner
        )
    }
    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("svndock-resolve-check-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw ResolveCheckFailure(message: message) }
    }
}

private struct ResolveCheckFailure: Error { let message: String }

private actor ResolveVerificationFixtureRunner: ProcessRunning {
    enum Outcome: CaseIterable, Sendable {
        case successWithSiblingConflict, remainingText, remainingProperty, remainingTree
        case failedStatus, malformedStatus, cancelledStatus, fileExternal, differentWorkingCopy
        case inRootSymlink, symlinkAfterInfo
    }
    let root: URL
    let outcome: Outcome
    private(set) var invocations: [ProcessInvocation] = []
    private var statusCount = 0
    init(root: URL, outcome: Outcome) { self.root = root; self.outcome = outcome }
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        invocations.append(invocation)
        switch invocation.arguments.first {
        case "info":
            if outcome == .symlinkAfterInfo {
                let selected = root.appendingPathComponent("text.txt")
                try FileManager.default.removeItem(at: selected)
                try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: root.appendingPathComponent("sibling.txt"))
            }
            let actualRoot = outcome == .differentWorkingCopy ? root.appendingPathComponent("nested") : root
            return result("<info><entry kind=\"file\" path=\"text.txt\" revision=\"1\"><url>file:///fixture/text.txt</url><wc-info><wcroot-abspath>\(actualRoot.path)</wcroot-abspath><schedule>normal</schedule></wc-info></entry></info>")
        case "resolve": return result("")
        case "status":
            statusCount += 1
            if statusCount == 1 {
                return result(statusXML(item: "conflicted", external: outcome == .fileExternal))
            }
            switch outcome {
            case .failedStatus: return result("", exit: 1)
            case .malformedStatus: return result("not xml")
            case .cancelledStatus: throw CancellationError()
            case .remainingText: return result(statusXML(item: "conflicted"))
            case .remainingProperty: return result(statusXML(item: "normal", props: "conflicted"))
            case .remainingTree: return result(statusXML(item: "normal", tree: true))
            default: return result(statusXML(item: "modified"))
            }
        default: throw ResolveCheckFailure(message: "unexpected resolve fixture command")
        }
    }
    private func statusXML(item: String, props: String = "none", tree: Bool = false, external: Bool = false) -> String {
        "<status><target path=\".\"><entry path=\"text.txt\"><wc-status item=\"\(item)\" props=\"\(props)\" revision=\"1\" tree-conflicted=\"\(tree)\" file-external=\"\(external)\"/></entry><entry path=\"sibling.txt\"><wc-status item=\"conflicted\" props=\"none\" revision=\"1\"/></entry></target></status>"
    }
    private func result(_ text: String, exit: Int32 = 0) -> ProcessResult {
        ProcessResult(terminationStatus: exit, terminationReason: .exit, standardOutput: Data(text.utf8), standardError: Data("fixture status unavailable".utf8))
    }
}

private actor ResolveIntegrationRunner: ProcessRunning {
    let configuration: URL
    private(set) var resolveCount = 0
    init(configuration: URL) { self.configuration = configuration }
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        if invocation.arguments.first == "resolve" { resolveCount += 1 }
        return try await ProcessRunner().run(ProcessInvocation(
            executableURL: invocation.executableURL,
            arguments: ["--config-dir", configuration.path, "--no-auth-cache", "--non-interactive"] + invocation.arguments,
            currentDirectoryURL: invocation.currentDirectoryURL,
            environment: invocation.environment,
            standardInput: invocation.standardInput,
            argumentFiles: invocation.argumentFiles.map { ProcessArgumentFile(argumentIndex: $0.argumentIndex + 4, contents: $0.contents) }
        ))
    }
}
