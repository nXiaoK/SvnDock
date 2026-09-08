import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

@MainActor
enum LargeDirectoryDeletionRegressionChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    @discardableResult
    static func run() async throws -> Bool {
        guard let executable = SVNExecutableLocator.defaultCandidatePaths.map({ URL(fileURLWithPath: $0) })
            .first(where: {
                FileManager.default.isExecutableFile(atPath: $0.path)
                    && FileManager.default.isExecutableFile(atPath: $0.deletingLastPathComponent()
                        .appendingPathComponent("svnadmin").path)
            }) else {
            print("SKIP large directory deletion integration: SVN and svnadmin are unavailable")
            return false
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("svndock-large-directory-deletion-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let configuration = temporary.appendingPathComponent("svn-config")
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: false)
        try Data("[miscellany]\nenable-auto-props = no\nglobal-ignores =\n".utf8)
            .write(to: configuration.appendingPathComponent("config"))
        let runner = LargeDirectoryDeletionRunner(configuration: configuration)
        let repository = temporary.appendingPathComponent("repository")
        let root = temporary.appendingPathComponent("wc")
        let created = try await ProcessRunner().run(ProcessInvocation(
            executableURL: executable.deletingLastPathComponent().appendingPathComponent("svnadmin"),
            arguments: ["create", repository.path]))
        try check(created.succeeded, "create isolated large deletion repository")
        func svn(_ arguments: [String], in directory: URL? = nil) async throws -> ProcessResult {
            let result = try await runner.run(ProcessInvocation(executableURL: executable,
                arguments: arguments, currentDirectoryURL: directory ?? root))
            try check(result.succeeded, "large deletion fixture SVN failed: \(result.standardErrorString)")
            return result
        }
        _ = try await svn(["checkout", repository.absoluteString, root.path], in: temporary)
        let removedPath = "removed project @ 树"
        let nested = root.appendingPathComponent(removedPath).appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let fileCount = 4_100
        for index in 0..<fileCount {
            try Data(String(repeating: "original deleted child \(index)\n", count: 40).utf8)
                .write(to: nested.appendingPathComponent("file-\(index).txt"))
        }
        try Data("unchanged repository sibling\n".utf8).write(to: root.appendingPathComponent("sibling.txt"))
        try Data("standalone deleted file\n".utf8).write(to: root.appendingPathComponent("deleted.txt"))
        _ = try await svn(["add", "--force", "--", "."])
        _ = try await svn(["commit", "-m", "Seed large directory deletion regression", "--", "."])
        _ = try await svn(["delete", "--", removedPath + "@", "deleted.txt"])
        try Data("unselected local sibling edit\n".utf8).write(to: root.appendingPathComponent("sibling.txt"))

        let service = try CoreSvnDockService(
            sharedStore: FinderSharedStore(directoryURL: temporary.appendingPathComponent("shared")),
            executableLocator: SVNExecutableLocator(candidatePaths: [executable.path],
                environmentOverrideKey: "SVNDOCK_LARGE_DIRECTORY_DELETION_TEST_UNUSED"),
            processRunner: runner)
        let copy = try await service.registerWorkingCopy(at: root)
        let suiteName = "svndock-large-directory-deletion-drafts-\(UUID())"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw Failure(description: "create isolated large deletion draft storage")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SvnDockStore(service: service, commitDraftStore: SvnDockCommitDraftStore(defaults: defaults))
        try check(await store.load(), "load real large deletion working copy")
        guard let directory = store.entries.first(where: { $0.relativePath == removedPath }) else {
            throw Failure(description: "deleted directory is represented in the status snapshot")
        }
        try check(directory.nodeKind == .directory && directory.status == .deleted,
                  "deleted directory kind comes from SVN metadata after disk removal")
        store.selectedEntryIDs = [directory.id]
        store.requestCommit()
        try check(store.isPresentingCommit && store.commitWorkingCopy?.id == copy.id,
                  "opening commit keeps the reviewed working copy")

        let beforeDirectoryPreview = await runner.diffInvocations.count
        let summary = try await store.diffText(for: SvnDockDiffRequest(
            workingCopyID: copy.id, relativePath: removedPath))
        try check(!summary.isEmpty && summary.utf8.count < 4_096
                    && !summary.contains("Index:") && !summary.contains("@@"),
                  "commit and standalone directory previews return a bounded summary")
        store.cancelCommit()
        try check(await store.loadDiffForSelection() && store.diffText == summary && !store.isLoadingDiff,
                  "workspace selection uses the same immediate directory deletion summary")
        try check(await runner.diffInvocations.count == beforeDirectoryPreview,
                  "directory preview never invokes recursive SVN diff regardless of descendant count")

        let childPath = removedPath + "/nested/file-0.txt"
        let childDiff = try await store.diffText(for: SvnDockDiffRequest(
            workingCopyID: copy.id, relativePath: childPath))
        try check(childDiff.contains("-original deleted child 0") && childDiff.contains("@@"),
                  "an explicitly requested deleted child retains its complete text diff")
        let fileDiff = try await store.diffText(for: SvnDockDiffRequest(
            workingCopyID: copy.id, relativePath: "deleted.txt"))
        try check(fileDiff.contains("-standalone deleted file") && fileDiff.contains("@@"),
                  "ordinary deleted files retain their complete text diff")
        let fileInvocations = await runner.diffInvocations
        try check(fileInvocations.count == beforeDirectoryPreview + 2
                    && fileInvocations.suffix(2).allSatisfy { $0.outputByteLimit == 8 * 1_024 * 1_024 },
                  "only explicitly selected files invoke bounded diff commands")
        await runner.rejectNextDiffAsOversized()
        do {
            _ = try await store.diffText(for: SvnDockDiffRequest(
                workingCopyID: copy.id, relativePath: "deleted.txt"))
            throw Failure(description: "oversized diff must not return truncated preview content")
        } catch SvnDockServiceError.unavailable(let message) {
            try check(message.contains("差异超过预览大小限制") && message.contains("提交范围"),
                      "oversized output returns a readable preview-only limitation")
        }

        let beforeCommit = await runner.commitInvocations.count
        try await service.commit(workingCopy: copy, relativePaths: [removedPath],
                                 message: "Delete the selected large project tree")
        let commits = await runner.commitInvocations
        try check(commits.count == beforeCommit + 1
                    && commits.last?.argumentFiles.count == 1
                    && commits.last?.argumentFiles.first?.contents == Data(("./" + removedPath + "@\n").utf8)
                    && commits.last?.arguments.last == "--",
                  "large tree deletion commits one explicit directory target")
        let listing = try await svn(["list", "--recursive", repository.absoluteString])
        try check(listing.standardOutputString.split(separator: "\n").allSatisfy {
            !$0.hasPrefix(removedPath + "/")
        }, "selected directory deletion removes all 4,100 repository descendants")
        let sibling = try await svn(["cat", repository.appendingPathComponent("sibling.txt").absoluteString])
        try check(sibling.standardOutputString == "unchanged repository sibling\n",
                  "unselected sibling modification is excluded from the repository commit")
        let remaining = try await service.status(for: copy)
        try check(remaining.entries.contains { $0.relativePath == "sibling.txt" && $0.status == .modified }
                    && remaining.entries.contains { $0.relativePath == "deleted.txt" && $0.status == .deleted },
                  "unselected sibling modification and separate deletion remain pending locally")
        let logResult = try await svn(["log", "--xml", "--verbose", "--limit", "1", repository.absoluteString])
        let log = try SVNXMLParser.parseLog(logResult.standardOutput)
        try check(log.first?.changedPaths.map(\.path) == ["/" + removedPath],
                  "the committed revision changes exactly the selected directory tree")
        print("Large directory deletion regression passed: 4,100 descendants, no recursive preview command, bounded single-file diffs, complete tree commit and unselected edits preserved")
        return true
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
}

private actor LargeDirectoryDeletionRunner: ProcessRunning {
    let configuration: URL
    private(set) var diffInvocations: [ProcessInvocation] = []
    private(set) var commitInvocations: [ProcessInvocation] = []
    private var rejectsNextDiff = false

    init(configuration: URL) { self.configuration = configuration }

    func rejectNextDiffAsOversized() { rejectsNextDiff = true }

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        if invocation.arguments.first == "diff" {
            diffInvocations.append(invocation)
            if rejectsNextDiff {
                rejectsNextDiff = false
                throw ProcessRunnerError.outputLimitExceeded(invocation.outputByteLimit ?? 0)
            }
        }
        if invocation.arguments.first == "commit" { commitInvocations.append(invocation) }
        return try await ProcessRunner().run(ProcessInvocation(
            executableURL: invocation.executableURL,
            arguments: ["--config-dir", configuration.path, "--no-auth-cache"] + invocation.arguments,
            currentDirectoryURL: invocation.currentDirectoryURL, environment: invocation.environment,
            standardInput: invocation.standardInput,
            argumentFiles: invocation.argumentFiles.map {
                ProcessArgumentFile(argumentIndex: $0.argumentIndex + 3, contents: $0.contents)
            }, outputByteLimit: invocation.outputByteLimit))
    }
}
