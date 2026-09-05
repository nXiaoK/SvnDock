import Foundation
import Darwin
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum MissingRevertRegressionChecks {
    static func run() async throws {
        try await absentDirectoriesRestoreRecursively()
        try await propertyChangesStayShallow()
        try await freshStatusPreventsStaleRecursion()
        try await boundaryChangesPreventMutation()
        try await ambiguousAliasesDoNotRevert()
        try await statusRequestsAreBounded()
    }

    static func absentDirectoriesRestoreRecursively() async throws {
        let fixture = try RevertServiceFixture(entries: [
            "deleted": .init(status: "deleted", kind: "dir", schedule: "delete"),
            "deleted/child.txt": .init(status: "deleted", schedule: "delete"),
            "missing": .init(status: "missing", kind: "dir"),
            "missing/child.txt": .init(status: "missing"),
            "missing-file.txt": .init(status: "missing"),
            "edited-file.txt": .init(status: "modified")
        ])
        defer { fixture.remove() }
        try await fixture.service.revert(relativePaths: [
            "./deleted", "deleted/child.txt", fixture.root.appendingPathComponent("deleted").path,
            "missing", "missing/child.txt", "missing-file.txt", "edited-file.txt"
        ], in: fixture.copy)
        let calls = await fixture.runner.reverts
        try check(calls.count == 2, "revert groups recursive trees separately from shallow files")
        try check(calls[0].depth == "infinity" && Set(calls[0].paths) == ["deleted", "missing"],
                  "deleted and missing directories restore their complete trees once")
        try check(calls[1].depth == "empty" && Set(calls[1].paths) == ["missing-file.txt", "edited-file.txt"],
                  "missing and edited files retain exact-target revert behavior")
        let preflights = await fixture.runner.statusRequests
        try check(preflights.count == 1 && Set(preflights[0]).count == 6,
                  "equivalent absolute and relative targets are normalized and deduplicated")
    }

    static func propertyChangesStayShallow() async throws {
        let fixture = try RevertServiceFixture(entries: [
            "properties": .init(status: "normal", properties: "modified", kind: "dir"),
            "properties/edited.txt": .init(status: "modified")
        ])
        defer { fixture.remove() }
        try await fixture.service.revert(relativePaths: ["properties"], in: fixture.copy)
        let calls = await fixture.runner.reverts
        try check(calls.count == 1 && calls[0].depth == "empty" && calls[0].paths == ["properties"],
                  "reverting directory properties cannot discard unselected child edits")
        try check(await fixture.runner.infoRequests.isEmpty, "ordinary directory changes do not require info scans")
    }

    static func freshStatusPreventsStaleRecursion() async throws {
        let fixture = try RevertServiceFixture(entries: [
            "folder": .init(status: "deleted", kind: "dir", schedule: "delete")
        ])
        defer { fixture.remove() }
        try await fixture.service.revert(relativePaths: ["folder"], in: fixture.copy)
        await fixture.runner.setEntry("folder", .init(status: "normal", properties: "modified", kind: "dir"))
        try await fixture.service.revert(relativePaths: ["folder"], in: fixture.copy)
        let calls = await fixture.runner.reverts
        try check(calls.count == 2 && calls[0].depth == "infinity" && calls[1].depth == "empty",
                  "a previously deleted directory uses fresh status after changing to a property edit")

        // A newer schedule from info must also veto the older status result's
        // recursive plan if another SVN client changed the path during preflight.
        await fixture.runner.setEntry("folder", .init(status: "deleted", kind: "dir", schedule: "normal"))
        try await fixture.service.revert(relativePaths: ["folder"], in: fixture.copy)
        try check(await fixture.runner.reverts.last?.depth == "empty",
                  "an inconsistent current schedule cannot enable recursive revert")
    }

    static func boundaryChangesPreventMutation() async throws {
        let fixture = try RevertServiceFixture(entries: [
            "folder": .init(status: "missing", kind: "dir")
        ])
        defer { fixture.remove() }
        var rejected = false
        do {
            try await fixture.service.revert(relativePaths: ["../outside"], in: fixture.copy)
        } catch { rejected = true }
        let invalidStatusRequests = await fixture.runner.statusRequests
        try check(rejected && invalidStatusRequests.isEmpty,
                  "paths outside the working copy are rejected before invoking SVN")

        await fixture.runner.replaceTargetWithEscapingSymlink("folder")
        rejected = false
        do {
            try await fixture.service.revert(relativePaths: ["folder"], in: fixture.copy)
        } catch { rejected = true }
        let boundaryReverts = await fixture.runner.reverts
        try check(rejected && boundaryReverts.isEmpty,
                  "the final boundary check rejects a path replaced by an escaping symlink during info")
    }

    static func statusRequestsAreBounded() async throws {
        let paths = (0..<300).map { "file-\($0).txt" }
        let entries = Dictionary(uniqueKeysWithValues: paths.map {
            ($0, RevertTestRunner.Entry(status: "modified"))
        })
        let fixture = try RevertServiceFixture(entries: entries)
        defer { fixture.remove() }
        try await fixture.service.revert(relativePaths: paths, in: fixture.copy)
        let requests = await fixture.runner.statusRequests
        try check(requests.count == 2 && requests.allSatisfy { $0.count <= 256 }
                  && Set(requests.flatMap { $0 }) == Set(paths),
                  "large selections complete bounded status batches before mutation")
        let calls = await fixture.runner.reverts
        try check(calls.count == 1 && calls[0].depth == "empty" && Set(calls[0].paths) == Set(paths),
                  "batching preflight preserves every selected file in the eventual revert")
    }

    static func ambiguousAliasesDoNotRevert() async throws {
        let fixture = try RevertServiceFixture(entries: ["edited.txt": .init(status: "modified")])
        defer { fixture.remove() }
        let alias = fixture.temporary.appendingPathComponent("working-copy-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
        let copy = SvnDockWorkingCopy(name: "aliased fixture", rootURL: alias)
        let physicalRoot = try fixture.root.path.withCString { path -> String in
            guard let resolved = realpath(path, nil) else {
                throw MissingRevertFailure(message: "cannot resolve the fixture's physical root")
            }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        // Keep the actual physical spelling: URL.path may simplify /private/var
        // back to /var, which is a different logical alias from the WC symlink.
        let physicalPath = physicalRoot + "/edited.txt"
        // Registration normally canonicalizes the WC root. A manually
        // constructed symlink root with a different absolute spelling is
        // ambiguous under Foundation normalization and must fail closed.
        var rejected = false
        do {
            try await fixture.service.revert(relativePaths: [physicalPath, "edited.txt"], in: copy)
        } catch is SVNCommandBuilderError {
            rejected = true
        } catch is SvnDockServiceError {
            rejected = true
        }
        let calls = await fixture.runner.reverts
        try check(rejected && calls.isEmpty,
                  "ambiguous symlink-root aliases cannot retarget a revert to another path")
    }

    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw MissingRevertFailure(message: message) }
    }
}

private struct RevertServiceFixture {
    let temporary: URL
    let root: URL
    let copy: SvnDockWorkingCopy
    let runner: RevertTestRunner
    let service: CoreSvnDockService

    init(entries: [String: RevertTestRunner.Entry]) throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("svndock-revert-\(UUID())")
        root = temporary.appendingPathComponent("wc", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        copy = SvnDockWorkingCopy(name: "revert fixture", rootURL: root)
        runner = RevertTestRunner(root: root, entries: entries)
        let shared = try FinderSharedStore(directoryURL: temporary.appendingPathComponent("shared"))
        service = try CoreSvnDockService(
            sharedStore: shared,
            executableLocator: SVNExecutableLocator(candidatePaths: ["/usr/bin/true"]),
            processRunner: runner
        )
    }

    func remove() { try? FileManager.default.removeItem(at: temporary) }
}

private actor RevertTestRunner: ProcessRunning {
    struct Entry: Sendable {
        var status: String
        var properties = "none"
        var kind = "file"
        var schedule = "normal"
    }
    struct Revert: Sendable {
        let depth: String
        let paths: [String]
    }

    let root: URL
    var entries: [String: Entry]
    private(set) var statusRequests: [[String]] = []
    private(set) var infoRequests: [[String]] = []
    private(set) var reverts: [Revert] = []
    private var escapingTarget: String?

    init(root: URL, entries: [String: Entry]) {
        self.root = root
        self.entries = entries
    }

    func setEntry(_ path: String, _ entry: Entry) { entries[path] = entry }
    func replaceTargetWithEscapingSymlink(_ path: String) { escapingTarget = path }

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        guard let separator = invocation.arguments.firstIndex(of: "--") else {
            throw MissingRevertFailure(message: "SVN invocation has no target separator")
        }
        let fileTargets = invocation.argumentFiles.flatMap { file in
            file.contents.split(separator: 0x0a).map { String(decoding: $0, as: UTF8.self) }
        }
        let paths = (fileTargets + Array(invocation.arguments[(separator + 1)...])).map { target in
            var path = target.hasPrefix("./") ? String(target.dropFirst(2)) : target
            if path.hasSuffix("@") { path.removeLast() }
            return path
        }
        guard let depthIndex = invocation.arguments.firstIndex(of: "--depth") else {
            throw MissingRevertFailure(message: "SVN invocation must choose an explicit depth")
        }
        let depth = invocation.arguments[depthIndex + 1]
        let xml: String
        switch invocation.arguments.first {
        case "status":
            guard depth == "empty" else { throw MissingRevertFailure(message: "revert preflight must be shallow") }
            statusRequests.append(paths)
            xml = "<status><target path=\".\">" + paths.compactMap { path in
                entries[path].map { entry in
                    """
                    <entry path="\(path)"><wc-status item="\(entry.status)" props="\(entry.properties)" revision="12"/></entry>
                    """
                }
            }.joined() + "</target></status>"
        case "info":
            guard depth == "empty" else { throw MissingRevertFailure(message: "revert metadata must be shallow") }
            infoRequests.append(paths)
            xml = "<info>" + paths.compactMap { path in
                entries[path].map { entry in
                    """
                    <entry path="\(path)" kind="\(entry.kind)" revision="12"><wc-info><wcroot-abspath>\(root.path)</wcroot-abspath><schedule>\(entry.schedule)</schedule></wc-info></entry>
                    """
                }
            }.joined() + "</info>"
            if let escapingTarget {
                self.escapingTarget = nil
                let outside = root.deletingLastPathComponent().appendingPathComponent("outside")
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(
                    at: root.appendingPathComponent(escapingTarget), withDestinationURL: outside
                )
            }
        case "revert":
            reverts.append(Revert(depth: depth, paths: paths))
            xml = ""
        default:
            throw MissingRevertFailure(message: "unexpected revert test invocation")
        }
        return ProcessResult(terminationStatus: 0, terminationReason: .exit,
                             standardOutput: Data(xml.utf8), standardError: Data())
    }
}

private struct MissingRevertFailure: Error { let message: String }
