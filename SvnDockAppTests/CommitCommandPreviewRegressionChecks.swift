import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum CommitCommandPreviewRegressionChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(description: message) }
    }

    @MainActor
    static func run() async throws {
        guard let executable = SVNExecutableLocator.defaultCandidatePaths.map({ URL(fileURLWithPath: $0) }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
                && FileManager.default.isExecutableFile(atPath: $0.deletingLastPathComponent().appendingPathComponent("svnadmin").path)
        }) else { throw Failure(description: "Command preview integration requires SVN and svnadmin") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("commit-command-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("wc '中文 空格")
        let repository = temporary.appendingPathComponent("repository")
        let runner = CommandPreviewRunner(configuration: temporary.appendingPathComponent("svn-config"))
        try await runner.prepareConfiguration()
        let admin = try await ProcessRunner().run(.init(executableURL: executable.deletingLastPathComponent().appendingPathComponent("svnadmin"), arguments: ["create", repository.path]))
        try check(admin.succeeded, "create preview fixture repository")
        @discardableResult
        func svn(_ arguments: [String], in directory: URL) async throws -> ProcessResult {
            let result = try await runner.run(.init(executableURL: executable, arguments: arguments, currentDirectoryURL: directory))
            try check(result.succeeded, "preview fixture SVN: \(result.standardErrorString)")
            return result
        }
        try await svn(["checkout", repository.absoluteString, root.path], in: temporary)
        let selected = ["alpha '引号' @.txt", "second $(touch SHOULD_NOT_EXIST).txt", "line space.txt"]
        let allPaths = selected + ["omitted.txt"]
        for path in allPaths { try Data("before\n".utf8).write(to: root.appendingPathComponent(path)) }
        try await svn(["add", "--"] + allPaths.map { $0.contains("@") ? $0 + "@" : $0 }, in: root)
        try await svn(["commit", "-m", "Initial fixture"], in: root)
        try await svn(["update"], in: root)
        for path in allPaths { try Data("after\n".utf8).write(to: root.appendingPathComponent(path)) }
        try await svn(["propset", "custom:scope", "unselected root property", "."], in: root)
        let shared = try FinderSharedStore(directoryURL: temporary.appendingPathComponent("shared"))
        let service = try CoreSvnDockService(sharedStore: shared,
            executableLocator: SVNExecutableLocator(candidatePaths: [executable.path]), processRunner: runner)
        let copy = try await service.registerWorkingCopy(at: root)
        let store = SvnDockStore(service: service)
        try check(await store.load(), "preview store loads")
        let ids = Set(store.entries.filter { selected.contains($0.relativePath) }.map(\.id))
        let rootID = store.entries.first { $0.relativePath == "." }!.id
        store.selectedEntryIDs = [rootID]
        store.searchQuery = "does not match checked files"
        store.requestCommit()
        let message = " \n提交 '引号' 与 $(literal)\n\n保留段落、中文和 `反引号`。\n "
        let request = try store.captureCommitCommandPreview(message: message, entryIDs: ids)
        try check(Set(request.relativePaths) == Set(selected), "preview follows checked IDs instead of the inspected root or filter")
        let countBefore = await runner.invocations.count
        let preview = try await store.loadCommitCommandPreview(request)
        try check(await runner.invocations.count == countBefore, "preview launches no SVN command or mutation")
        try check(store.isPresentingCommit && !store.isBusy && store.selectedEntryIDs == [rootID],
                  "preview preserves the commit sheet and inspected row")
        try check(preview.invocation.currentDirectoryURL?.path == root.path && !preview.hasEmptyMessage,
                  "preview retains the exact working directory and message")
        try check(preview.invocation.standardInput == Data(message.trimmingCharacters(in: .whitespacesAndNewlines).utf8),
                  "preview shows the exact normalized stdin bytes")
        let targets = preview.invocation.argumentFiles.map { String(decoding: $0.contents, as: UTF8.self) }.joined()
        try check(!targets.contains("omitted.txt") && !targets.split(separator: "\n").contains("./."),
                  "unchecked files and directory properties are absent from the target list")
        try check(targets.contains("alpha '引号' @.txt@") && targets.contains("line space.txt"),
                  "literal @ is peg escaped and spaces remain intact in the target file")
        var expected = [preview.invocation.executableURL.path] + preview.invocation.arguments
        for (index, file) in preview.invocation.argumentFiles.enumerated() { expected[file.argumentIndex + 1] = "<临时目标清单 \(index + 1)>" }
        let quoted = try await ProcessRunner().run(.init(executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s\\000' " + preview.commandLine], currentDirectoryURL: root))
        let actual = quoted.standardOutput.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
        try check(quoted.succeeded && actual == expected, "rendered shell quoting round-trips every argument without expansion")
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("SHOULD_NOT_EXIST").path),
                  "command-looking filename text cannot execute during quoting validation")

        store.commit(message: message, entryIDs: ids)
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while store.isBusy {
            guard ContinuousClock.now < deadline else { throw Failure(description: "fixture commit timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
        let executed = await runner.invocations.last { $0.arguments.first == "commit" }
        try check(executed == preview.invocation,
                  "the real selected commit executes exactly the previewed template, stdin and target-file bytes")
        let remaining = try await service.status(for: copy)
        try check(Set(remaining.entries.map(\.relativePath)) == [".", "omitted.txt"],
                  "the actual commit preserves unchecked root properties and file edits")
        let logged = try await svn(["log", "--xml", "--limit", "1", repository.absoluteString], in: root)
        try check(try SVNXMLParser.parseLog(logged.standardOutput).first?.message == request.message,
                  "the committed log message matches the preview exactly")

        store.searchQuery = ""
        store.requestCommit()
        let remainingIDs = Set(store.entries.filter { $0.relativePath == "omitted.txt" }.map(\.id))
        let blank = try store.captureCommitCommandPreview(message: " \n", entryIDs: remainingIDs)
        let emptyPreview = try await store.loadCommitCommandPreview(blank)
        try check(emptyPreview.hasEmptyMessage && emptyPreview.invocation.standardInput == Data(),
                  "an unfinished draft can preview argv without inventing a commit message")
        let beforeRejected = await runner.invocations.count
        store.commit(message: " \n", entryIDs: remainingIDs)
        let afterRejected = await runner.invocations.count
        try check(store.presentedError != nil && !store.isBusy && afterRejected == beforeRejected,
                  "real submissions still reject empty messages without starting SVN")
        store.presentedError = nil
        let revised = try store.captureCommitCommandPreview(message: "新的说明", entryIDs: remainingIDs)
        let revisedPreview = try await store.loadCommitCommandPreview(revised)
        try check(revised.id != request.id && revisedPreview.fullText.contains("新的说明")
                    && !revisedPreview.fullText.contains("alpha '引号' @.txt"),
                  "reopening captures the latest checkbox selection and message")
        store.cancelCommit()

        let large = try await service.commitCommandPreview(workingCopy: copy,
            relativePaths: (0..<12_000).map { "目录/file-\($0).txt" }, message: String(repeating: "说明", count: 90_000))
        try check(large.isTruncated && large.displayText.utf8.count <= 120_003
                    && large.fullText.contains("file-11999.txt") && large.fullText.utf8.count > large.displayText.utf8.count,
                  "large previews bound text layout while preserving all targets and message for copying")
        let builder = try SVNCommandBuilder(executableURL: executable)
        do {
            _ = try builder.makeInvocation(for: .commit(paths: ["omitted.txt"], message: "", keepLocks: false, depth: .empty), in: WorkingCopy(localPath: root))
            throw Failure(description: "production builder accepted an empty message")
        } catch SVNCommandBuilderError.emptyCommitMessage { }
        print("Commit command preview checks passed: no SVN execution, exact selected commit equivalence, stdin/targets, literal quoting, empty drafts, refreshed scope and large previews")
    }
}

private actor CommandPreviewRunner: ProcessRunning {
    let configuration: URL
    private(set) var invocations: [ProcessInvocation] = []
    init(configuration: URL) { self.configuration = configuration }
    func prepareConfiguration() throws {
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: false)
        try Data("[miscellany]\nenable-auto-props = no\nglobal-ignores =\n".utf8).write(to: configuration.appendingPathComponent("config"))
    }
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        invocations.append(invocation)
        return try await ProcessRunner().run(.init(executableURL: invocation.executableURL,
            arguments: ["--config-dir", configuration.path, "--no-auth-cache"] + invocation.arguments,
            currentDirectoryURL: invocation.currentDirectoryURL, environment: invocation.environment,
            standardInput: invocation.standardInput,
            argumentFiles: invocation.argumentFiles.map { .init(argumentIndex: $0.argumentIndex + 3, contents: $0.contents) }))
    }
}
