#if SVNDOCK_SMOKE_TESTS
import Foundation
import SvnDockCore

enum MissingDeletionSmoke {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func run() async throws {
        let copy = WorkingCopy(localPath: FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-delete-mock-\(UUID().uuidString)"))
        let executable = URL(fileURLWithPath: "/opt/homebrew/bin/svn")
        let builder = try SVNCommandBuilder(executableURL: executable)
        let deletion = try SVNMissingDeletion(executableURL: executable)
        let manyPaths = (0..<60_000).map { "gone/child-\($0).txt" }
        let collapsed = try deletion.targets(for: manyPaths + ["gone", "gone-other/file.txt", "gone"], in: copy)
        try check(collapsed == ["gone", "gone-other/file.txt"], "missing deletion collapses directory descendants without prefix collisions")
        for paths in [[String](), ["../outside"], ["."], [copy.localPath.path]] {
            do {
                _ = try deletion.targets(for: paths, in: copy)
                throw Failure(description: "missing deletion accepted empty, outside or root targets")
            } catch is SVNCommandBuilderError { } catch SVNMissingDeletionError.workingCopyRoot { }
        }

        let invocation = try builder.makeInvocation(
            for: .delete(paths: ["-option", "文件 space@x", "line\nbreak", "carriage\rreturn"]), in: copy
        )
        try check(invocation.arguments.prefix(2) == ["delete", "--keep-local"], "deletion preserves recreated disk content")
        try check(!invocation.arguments.contains("--force"), "deletion never forces through local changes")
        try check(invocation.argumentFiles.first?.contents == Data("./-option\n./文件 space@x@\n".utf8), "deletion targets stay local and escape peg syntax")
        try check(invocation.arguments.suffix(3) == ["--", "line\nbreak", "carriage\rreturn"], "deletion preserves newlines as literal argv")
        let largeInvocation = try builder.makeInvocation(for: .delete(paths: manyPaths), in: copy)
        try check(largeInvocation.arguments.count < 10, "large deletion keeps bounded argv")
        try check(largeInvocation.argumentFiles.first?.contents.split(separator: 0x0a).count == manyPaths.count, "large deletion retains every target")
        try check(SVNOperationKind.delete(paths: ["gone"]).mutatesWorkingCopy, "deletion participates in working-copy scheduling")

        let good = MissingDeletionFixtureRunner(copy: copy, entries: [.init(path: "gone")])
        try await SVNMissingDeletion(executableURL: executable, runner: good)
            .run(targets: ["gone", "gone/child"], in: copy)
        let goodCommands = await good.commands
        try check(goodCommands == ["status", "info", "delete"], "validated missing directory is deleted exactly once")

        for invalid in [
            MissingDeletionFixtureEntry(path: "invalid", schedule: "add", revision: "42"),
            MissingDeletionFixtureEntry(path: "invalid", schedule: "replace"),
            MissingDeletionFixtureEntry(path: "invalid", revision: "-1"),
            MissingDeletionFixtureEntry(path: "invalid", status: "normal"),
            MissingDeletionFixtureEntry(path: "invalid", treeConflict: true),
            MissingDeletionFixtureEntry(path: "invalid", propertyStatus: "conflicted"),
            MissingDeletionFixtureEntry(path: "invalid", nestedWorkingCopy: true)
        ] {
            let fixture = MissingDeletionFixtureRunner(copy: copy, entries: [.init(path: "gone"), invalid])
            do {
                try await SVNMissingDeletion(executableURL: executable, runner: fixture)
                    .run(targets: ["gone", "invalid"], in: copy)
                throw Failure(description: "mixed invalid selection must be rejected")
            } catch is SVNMissingDeletionError { }
            let commands = await fixture.commands
            try check(!commands.contains("delete"), "every selected target validates before any deletion")
        }

        for invalidChild in [
            MissingDeletionFixtureEntry(path: "gone/invalid", schedule: "add", revision: "-1"),
            MissingDeletionFixtureEntry(path: "gone/invalid", schedule: "replace"),
            MissingDeletionFixtureEntry(path: "gone/invalid", treeConflict: true),
            MissingDeletionFixtureEntry(path: "gone/invalid", propertyStatus: "conflicted")
        ] {
            let fixture = MissingDeletionFixtureRunner(copy: copy, entries: [.init(path: "gone"), invalidChild])
            do {
                try await SVNMissingDeletion(executableURL: executable, runner: fixture)
                    .run(targets: ["gone", "gone/invalid"], in: copy)
                throw Failure(description: "collapsed missing tree must validate its descendants")
            } catch is SVNMissingDeletionError { }
            let commands = await fixture.commands
            try check(!commands.contains("delete"), "parent collapse cannot conceal conflicting or uncommitted children")
        }

        let batchedEntries = (0..<600).map { MissingDeletionFixtureEntry(path: "file-\($0)") }
        let batched = MissingDeletionFixtureRunner(copy: copy, entries: batchedEntries)
        try await SVNMissingDeletion(executableURL: executable, runner: batched)
            .run(targets: batchedEntries.map(\.path), in: copy)
        let batchedCommands = await batched.commands
        try check(batchedCommands == ["status", "status", "status", "info", "delete"], "status reads batch before one large delete")

        try FileManager.default.createDirectory(at: copy.localPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy.localPath) }
        let restored = copy.localPath.appendingPathComponent("restored")
        let raced = MissingDeletionFixtureRunner(copy: copy, entries: [.init(path: "restored")], restoreDuringInfo: restored)
        do {
            try await SVNMissingDeletion(executableURL: executable, runner: raced).run(targets: ["restored"], in: copy)
            throw Failure(description: "restored file must block deletion")
        } catch SVNMissingDeletionError.notMissing { }
        let racedCommands = await raced.commands
        try check(!racedCommands.contains("delete"), "final disk check rejects file restored during validation")
        let restoredContent = try Data(contentsOf: restored)
        try check(restoredContent == Data("restored content".utf8), "restored content remains intact")

        let link = copy.localPath.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "absent")
        do {
            try await deletion.run(targets: ["dangling"], in: copy)
            throw Failure(description: "dangling symlink must count as present")
        } catch SVNMissingDeletionError.notMissing { }

        if ProcessInfo.processInfo.environment["SVNDOCK_MISSING_DELETE_INTEGRATION"] == "1" {
            try await realWorkingCopyCheck()
        }
        print("Missing deletion checks passed: local argv, large selections, complete preflight, schedule/conflict/root guards and restored files")
    }

    private static func realWorkingCopyCheck() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("svndock-delete-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let runner = ProcessRunner()
        let executable = try SVNExecutableLocator().locate()
        let admin = executable.deletingLastPathComponent().appendingPathComponent("svnadmin")
        let repository = temporary.appendingPathComponent("repository")
        let root = temporary.appendingPathComponent("wc")
        for invocation in [
            ProcessInvocation(executableURL: admin, arguments: ["create", repository.path]),
            ProcessInvocation(executableURL: executable, arguments: ["checkout", repository.absoluteString, root.path])
        ] {
            let result = try await runner.run(invocation)
            try check(result.succeeded, "disposable repository setup: \(result.standardErrorString)")
        }
        let copy = WorkingCopy(localPath: root)
        let builder = try SVNCommandBuilder(executableURL: executable)
        let deletion = try SVNMissingDeletion(executableURL: executable, runner: runner)
        func run(_ operation: SVNOperationKind) async throws -> ProcessResult {
            let result = try await runner.run(builder.makeInvocation(for: operation, in: copy))
            try check(result.succeeded, "real missing deletion command: \(result.standardErrorString)")
            return result
        }
        let directory = root.appendingPathComponent("gone tree")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let special = root.appendingPathComponent("-已提交 @ 文件.txt")
        let child = directory.appendingPathComponent("child.txt")
        for file in [special, child] { try Data("original content".utf8).write(to: file) }
        _ = try await run(.add(paths: [special.path, directory.path], parents: false, force: false, depth: .infinity))
        _ = try await run(.commit(paths: [special.path, directory.path], message: "Seed missing deletion fixture", keepLocks: false))

        // A copied descendant inherits an info revision and normal schedule,
        // but has not yet been committed at its new path.
        let copied = root.appendingPathComponent("pending-copy")
        let copyResult = try await runner.run(ProcessInvocation(
            executableURL: executable, arguments: ["copy", "--", directory.path, copied.path]
        ))
        try check(copyResult.succeeded, "seed pending copied subtree")
        let copiedChild = copied.appendingPathComponent("child.txt")
        try FileManager.default.removeItem(at: copiedChild)
        do {
            try await deletion.run(targets: [copiedChild.path], in: copy)
            throw Failure(description: "pending copied child must not count as already committed")
        } catch SVNMissingDeletionError.notCommitted { }
        _ = try await run(.revert(paths: [copied.path], depth: .infinity))
        if FileManager.default.fileExists(atPath: copied.path) { try FileManager.default.removeItem(at: copied) }

        let nested = root.appendingPathComponent("nested-wc")
        let nestedCheckout = try await runner.run(ProcessInvocation(
            executableURL: executable, arguments: ["checkout", repository.absoluteString, nested.path]
        ))
        try check(nestedCheckout.succeeded, "seed independent nested working copy")
        let nestedFile = nested.appendingPathComponent(special.lastPathComponent)
        try FileManager.default.removeItem(at: nestedFile)
        do {
            try await deletion.run(targets: [nestedFile.path], in: copy)
            throw Failure(description: "nested working-copy file must not be mutated from its parent")
        } catch SVNMissingDeletionError.differentWorkingCopy { }
        try FileManager.default.removeItem(at: nested)

        let pendingChild = directory.appendingPathComponent("pending-child.txt")
        try Data("pending child".utf8).write(to: pendingChild)
        _ = try await run(.add(paths: [pendingChild.path], parents: false, force: false, depth: nil))
        try FileManager.default.removeItem(at: special)
        try FileManager.default.removeItem(at: directory)
        let targets = [special.path, directory.path, child.path]
        let missing = try await run(.status(SVNStatusOptions()))
        let missingEntries = try SVNXMLParser.parseStatus(missing.standardOutput, workingCopyURL: root)
        try check(missingEntries.contains { $0.status == .missing }, "real disk removal produces missing status")
        do {
            try await deletion.run(targets: targets + [pendingChild.path], in: copy)
            throw Failure(description: "pending child hidden by directory collapse must block deletion")
        } catch SVNMissingDeletionError.notCommitted { }
        _ = try await run(.revert(paths: [pendingChild.path], depth: .empty))

        let pending = root.appendingPathComponent("pending-add.txt")
        try Data("pending".utf8).write(to: pending)
        _ = try await run(.add(paths: [pending.path], parents: false, force: false, depth: nil))
        try FileManager.default.removeItem(at: pending)
        do {
            try await deletion.run(targets: targets + [pending.path], in: copy)
            throw Failure(description: "real pending addition must block mixed deletion")
        } catch SVNMissingDeletionError.notCommitted { }
        let afterRejected = try await run(.status(SVNStatusOptions()))
        let rejectedEntries = try SVNXMLParser.parseStatus(afterRejected.standardOutput, workingCopyURL: root)
        try check(!rejectedEntries.contains { $0.status == .deleted }, "mixed selection rejection leaves all schedules unchanged")
        _ = try await run(.revert(paths: [pending.path], depth: .empty))

        try await deletion.run(targets: targets, in: copy)
        let scheduled = try await run(.status(SVNStatusOptions()))
        let scheduledEntries = try SVNXMLParser.parseStatus(scheduled.standardOutput, workingCopyURL: root)
        try check(scheduledEntries.count == 2 && scheduledEntries.allSatisfy { $0.status == .deleted }, "real missing file and directory become scheduled deletions")
        let childInfo = try await run(.infoTargets(paths: [child.path]))
        let deletedChild = try SVNXMLParser.parseInfo(childInfo.standardOutput)
        try check(deletedChild.schedule == "delete", "directory deletion includes its missing child")
        _ = try await run(.revert(paths: [special.path, directory.path], depth: .infinity))
        try check(FileManager.default.fileExists(atPath: special.path) && FileManager.default.fileExists(atPath: child.path), "revert restores scheduled file and directory deletions")

        // Recheck stale UI selection against files already restored on disk.
        do {
            try await deletion.run(targets: [special.path], in: copy)
            throw Failure(description: "real restored file must block stale missing selection")
        } catch SVNMissingDeletionError.notMissing { }
        try FileManager.default.removeItem(at: special)
        try FileManager.default.removeItem(at: directory)
        try await deletion.run(targets: targets, in: copy)
        _ = try await run(.commit(paths: [special.path, directory.path], message: "Commit intended missing deletions", keepLocks: false))
        _ = try await run(.update(revision: nil))
        try check(!FileManager.default.fileExists(atPath: special.path) && !FileManager.default.fileExists(atPath: directory.path), "update does not restore committed deletions")
        let clean = try await run(.status(SVNStatusOptions()))
        let cleanEntries = try SVNXMLParser.parseStatus(clean.standardOutput, workingCopyURL: root)
        try check(cleanEntries.isEmpty, "committed deletion leaves clean working copy")

        let raceFile = root.appendingPathComponent("recreated-after-validation.txt")
        try Data("original".utf8).write(to: raceFile)
        _ = try await run(.add(paths: [raceFile.path], parents: false, force: false, depth: nil))
        _ = try await run(.commit(paths: [raceFile.path], message: "Seed recreated file fixture", keepLocks: false))
        try FileManager.default.removeItem(at: raceFile)
        let raced = MissingDeletionRecreatingRunner(file: raceFile)
        try await SVNMissingDeletion(executableURL: executable, runner: raced).run(targets: [raceFile.path], in: copy)
        let recreated = try Data(contentsOf: raceFile)
        try check(recreated == Data("new content survives".utf8), "--keep-local preserves file recreated immediately before svn delete")
        print("Real missing deletion passed: ! → D → revert; ! → D → commit → update; pending-add rejection and recreated-content preservation")
    }
}

private struct MissingDeletionFixtureEntry: Sendable {
    let path: String
    var status = "missing"
    var schedule = "normal"
    var revision = "1"
    var treeConflict = false
    var propertyStatus = "none"
    var nestedWorkingCopy = false
}

private actor MissingDeletionFixtureRunner: ProcessRunning {
    let copy: WorkingCopy
    let entries: [MissingDeletionFixtureEntry]
    let restoreDuringInfo: URL?
    var commands: [String] = []

    init(copy: WorkingCopy, entries: [MissingDeletionFixtureEntry], restoreDuringInfo: URL? = nil) {
        self.copy = copy
        self.entries = entries
        self.restoreDuringInfo = restoreDuringInfo
    }

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        let command = invocation.arguments[0]
        commands.append(command)
        let xml: String
        switch command {
        case "status":
            let separator = invocation.arguments.lastIndex(of: "--")!
            let selected = Set(invocation.arguments.suffix(from: separator + 1))
            xml = "<status><target path=\".\">" + entries.filter { entry in
                selected.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") }
            }.map {
                "<entry path=\"\($0.path)\"><wc-status item=\"\($0.status)\" props=\"\($0.propertyStatus)\" revision=\"\($0.revision)\" tree-conflicted=\"\($0.treeConflict)\"/></entry>"
            }.joined() + "</target></status>"
        case "info":
            if let restoreDuringInfo { try Data("restored content".utf8).write(to: restoreDuringInfo) }
            xml = "<info>" + entries.map {
                let root = $0.nestedWorkingCopy ? copy.localPath.appendingPathComponent("nested") : copy.localPath
                return "<entry path=\"\($0.path)\" kind=\"file\" revision=\"\($0.revision)\"><wc-info><schedule>\($0.schedule)</schedule><wcroot-abspath>\(root.path)</wcroot-abspath></wc-info></entry>"
            }.joined() + "</info>"
        default:
            xml = ""
        }
        return ProcessResult(terminationStatus: 0, terminationReason: .exit, standardOutput: Data(xml.utf8), standardError: Data())
    }
}

private struct MissingDeletionRecreatingRunner: ProcessRunning {
    let file: URL

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        if invocation.arguments.first == "delete" {
            try Data("new content survives".utf8).write(to: file)
        }
        return try await ProcessRunner().run(invocation)
    }
}
#endif
