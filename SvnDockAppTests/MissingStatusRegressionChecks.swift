import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum MissingStatusRegressionChecks {
    static func run() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("svndock-missing-status-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("wc", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let shared = try FinderSharedStore(directoryURL: temporary.appendingPathComponent("shared"))
        let runner = MissingStatusRunner()
        let service = try CoreSvnDockService(
            sharedStore: shared,
            executableLocator: SVNExecutableLocator(candidatePaths: ["/usr/bin/true"]),
            processRunner: runner
        )
        let copy = SvnDockWorkingCopy(name: "fixture", rootURL: root)
        _ = try await shared.register(SvnDockCore.WorkingCopy(
            id: copy.id, name: copy.name, localPath: root
        ))
        let snapshot = try await service.status(for: copy)
        try check(snapshot.missingVersionedCount == 2, "committed missing files and directories are counted")
        try check(snapshot.missingAdditionCount == 2, "copied pending additions are classified by schedule")
        let entries = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.relativePath, $0) })
        try check(entries["copied-add.txt"]?.isMissingScheduledAddition == true,
                  "a source revision does not turn a copied addition into a committed file")
        try check(entries["copied-child.txt"]?.workingCopySchedule == "normal"
                  && entries["copied-child.txt"]?.workingCopyRevision == -1
                  && entries["copied-child.txt"]?.isMissingVersioned == false,
                  "a child of an uncommitted copy has no BASE despite a normal schedule and info source revision")
        try check(entries["folder"]?.nodeKind == .directory,
                  "missing empty directories retain the kind reported by SVN info")
        try check(entries["deleted-folder"]?.nodeKind == .directory
                  && entries["deleted-folder"]?.status == .deleted,
                  "scheduled deletions retain their directory kind after disappearing from disk")
        try check(entries["unknown.txt"]?.isMissingVersioned == false,
                  "unknown schedules cannot offer deletion")
        try check(entries["replace.txt"]?.isMissingVersioned == false,
                  "pending replacements cannot offer deletion as normal nodes")
        try check(entries["conflict.txt"]?.isMissingVersioned == false,
                  "conflicted missing nodes cannot offer deletion")
        let firstInfoCount = await runner.infoCount
        try check(firstInfoCount == 1, "missing status metadata is batched into one info call")

        let children = try await service.directoryChildren(relativePath: ".", in: copy)
        try check(children.first { $0.relativePath == "copied-add.txt" }?.isMissingScheduledAddition == true,
                  "directory children preserve missing-addition classification")
        try check(children.first { $0.relativePath == "folder" }?.nodeKind == .directory,
                  "directory children preserve the kind of an empty missing directory")
        try check(children.first { $0.relativePath == "deleted-folder" }?.nodeKind == .directory,
                  "directory listings preserve scheduled-deletion directories")
        try check(children.first { $0.relativePath == "copied-child.txt" }?.isMissingVersioned == false,
                  "directory children preserve the absent BASE of an uncommitted copy child")

        await runner.failInfo()
        let unclassified = try await service.status(for: copy)
        try check(unclassified.entries.count == snapshot.entries.count,
                  "an info failure does not hide the status snapshot")
        try check(unclassified.missingVersionedCount == 0 && unclassified.missingAdditionCount == 0,
                  "an info failure leaves schedules unclassified")

        let mock = MockSvnDockService(workingCopies: [copy], entriesByWorkingCopyID: [copy.id: snapshot.entries])
        try await mock.cleanupMissingAdditions(relativePaths: ["committed.txt", "copied-add.txt"], in: copy)
        let cleaned = try await mock.status(for: copy)
        try check(cleaned.entries.contains { $0.relativePath == "committed.txt" },
                  "mock missing-addition cleanup preserves committed missing files")
        try check(!cleaned.entries.contains { $0.relativePath == "copied-add.txt" },
                  "mock missing-addition cleanup removes only pending additions")
        try await mock.scheduleMissingDeletion(relativePaths: ["committed.txt"], in: copy)
        let deleted = try await mock.status(for: copy)
        try check(deleted.entries.first { $0.relativePath == "committed.txt" }?.status == .deleted,
                  "mock deletion turns a missing committed file into a committable deletion")

        let syntheticConflict = SvnDockStatusEntry(
            workingCopyID: copy.id, relativePath: "conflicted-add.txt", nodeKind: .file,
            status: .missing, conflictKinds: [.tree], workingCopySchedule: "add"
        )
        try check(!syntheticConflict.isMissingScheduledAddition,
                  "missing addition eligibility rejects explicit conflicts")
        let unknownBase = SvnDockStatusEntry(
            workingCopyID: copy.id, relativePath: "unknown-base.txt", nodeKind: .file,
            status: .missing, workingCopySchedule: "normal"
        )
        try check(!unknownBase.isMissingVersioned,
                  "a normal schedule with unknown BASE revision cannot offer deletion")
    }

    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw MissingStatusFailure(message: message) }
    }
}

private actor MissingStatusRunner: ProcessRunning {
    var infoCount = 0
    private var infoFails = false
    private let fixtures: [(path: String, schedule: String?, revision: Int, copied: Bool, conflict: Bool, kind: String)] = [
        ("committed.txt", "normal", 12, false, false, "file"),
        ("plain-add.txt", "add", 0, false, false, "file"),
        ("copied-add.txt", "add", 12, true, false, "file"),
        ("copied-child.txt", "normal", -1, false, false, "file"),
        ("folder", "normal", 12, false, false, "dir"),
        ("deleted-folder", "delete", 12, false, false, "dir"),
        ("unknown.txt", nil, 12, false, false, "file"),
        ("replace.txt", "replace", 12, false, false, "file"),
        ("conflict.txt", "normal", 12, false, true, "file")
    ]

    func failInfo() { infoFails = true }

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        let xml: String
        switch invocation.arguments.first {
        case "status":
            xml = "<status><target path=\".\">" + fixtures.map { fixture in
                """
                <entry path="\(fixture.path)"><wc-status item="\(fixture.schedule == "delete" ? "deleted" : "missing")" props="none" revision="\(fixture.revision)" copied="\(fixture.copied)" tree-conflicted="\(fixture.conflict)"/></entry>
                """
            }.joined() + "</target></status>"
        case "info":
            infoCount += 1
            if infoFails {
                return ProcessResult(terminationStatus: 1, terminationReason: .exit,
                                     standardOutput: Data(), standardError: Data("transient info failure".utf8))
            }
            guard invocation.arguments.contains("--depth"), invocation.arguments.contains("empty") else {
                throw MissingStatusFailure(message: "missing schedules must use shallow info")
            }
            let fileTargets = invocation.argumentFiles.flatMap {
                String(decoding: $0.contents, as: UTF8.self).split(separator: "\n").map(String.init)
            }
            let separator = invocation.arguments.firstIndex(of: "--")!
            let requested = Set((fileTargets + Array(invocation.arguments[(separator + 1)...])).map {
                $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0
            })
            xml = "<info>" + fixtures.filter { requested.contains($0.path) }.map { fixture in
                let schedule = fixture.schedule.map { "<schedule>\($0)</schedule>" } ?? ""
                return """
                <entry path="\(fixture.path)" kind="\(fixture.kind)" revision="\(fixture.revision < 0 ? 12 : fixture.revision)"><wc-info>\(schedule)</wc-info></entry>
                """
            }.joined() + "</info>"
        default:
            throw MissingStatusFailure(message: "unexpected status test invocation")
        }
        return ProcessResult(terminationStatus: 0, terminationReason: .exit,
                             standardOutput: Data(xml.utf8), standardError: Data())
    }
}

private struct MissingStatusFailure: Error { let message: String }
