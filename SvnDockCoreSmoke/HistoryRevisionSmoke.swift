#if SVNDOCK_SMOKE_TESTS
import Foundation
import SvnDockCore

enum HistoryRevisionSmoke {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func run() async throws {
        let copy = WorkingCopy(localPath: URL(fileURLWithPath: "/tmp/history-smoke"))
        let builder = try SVNCommandBuilder(executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/svn"))
        let root = URL(string: "https://example.com/svn/repo%20space")!
        let changed = SVNChangedPath(path: "/trunk/中文 @.txt", action: .deleted, kind: .file)
        let diff = try builder.makeInvocation(for: .revisionDiff(repositoryRoot: root, revision: 8, change: changed), in: copy)
        try check(diff.arguments.contains(root.absoluteString + "@7"), "historical old root pinned")
        try check(diff.arguments.contains(root.absoluteString + "@8"), "historical new root pinned")
        try check(diff.arguments.suffix(2) == ["--", "trunk/中文 @.txt"], "historical special path kept literal")
        try check(!SVNOperationKind.revisionDiff(repositoryRoot: root, revision: 8, change: changed).mutatesWorkingCopy, "historical diff read-only")
        let copied = SVNChangedPath(path: "/trunk/new.txt", action: .added, kind: .file,
                                    copyFromPath: "/branches/old @.txt", copyFromRevision: 2)
        let copyDiff = try builder.makeInvocation(for: .revisionDiff(repositoryRoot: root, revision: 8, change: copied), in: copy)
        try check(copyDiff.arguments.contains(root.appendingPathComponent("branches/old @.txt").absoluteString + "@2"), "copy uses actual source revision")
        for revision in [0, -1] {
            do {
                _ = try builder.makeInvocation(for: .revisionSummary(repositoryRoot: root, revision: revision), in: copy)
                throw Failure(description: "invalid revision accepted")
            } catch is SVNCommandBuilderError { }
        }
        for path in ["relative", "/../escape", "/a//b", "/a/./b", "/bad\0path"] {
            do { _ = try SVNRepositoryPath.validate(path); throw Failure(description: "invalid repo path accepted") }
            catch is SVNCommandBuilderError { }
        }
        let decoded = try SVNRepositoryPath.path(for: root.appendingPathComponent("trunk/中文 @.txt").absoluteString, in: root)
        try check(decoded == "/trunk/中文 @.txt", "summary URL decoding")

        let xml = """
        <log><logentry revision="8"><author>作者</author><paths>
        <path action="A" kind="dir" copyfrom-path="/old" copyfrom-rev="2">/new</path>
        <path action="D" kind="dir">/old</path>
        <path action="M" kind="file">/new/edited.txt</path>
        <path action="A" kind="file">/new/added.txt</path>
        </paths><msg>move &amp; edit</msg></logentry></log>
        """
        let entry = try SVNXMLParser.parseLog(Data(xml.utf8))[0]
        try check(entry.changedPaths[0].kind == .directory && entry.changedPaths[0].copyFromRevision == 2, "verbose log ancestry")
        let paths = [("/new", "dir", "added"), ("/new/child.txt", "file", "added"), ("/new/edited.txt", "file", "added"), ("/new/added.txt", "file", "added"), ("/old", "dir", "deleted"), ("/old/child.txt", "file", "deleted"), ("/old/edited.txt", "file", "deleted")]
        let summaryXML = "<diff><paths>" + paths.map {
            "<path kind=\"\($0.1)\" item=\"\($0.2)\">\(root.absoluteString)\($0.0)</path>"
        }.joined() + "</paths></diff>"
        let details = try SVNRevisionDetails.combining(repositoryRootURL: root, entry: entry,
            summary: SVNXMLParser.parseDiffSummary(Data(summaryXML.utf8)))
        try check(details.changes.count == 4, "move pairs collapsed and directory children retained")
        try check(details.changes.first { $0.path == "/new/edited.txt" }?.copyFromPath == "/old/edited.txt", "modified copied descendant inherits ancestry")
        try check(details.changes.first { $0.path == "/new/child.txt" }?.isMove == true, "implicit copied descendant move")
        try check(details.changes.first { $0.path == "/new/added.txt" }?.copyFromPath == nil, "new child must not invent copy ancestry")

        let rootCopy = SVNLogEntry(revision: 8, author: nil, date: nil, message: "root copy", changedPaths: [
            SVNChangedPath(path: "/snapshot", action: .added, kind: .directory, copyFromPath: "/", copyFromRevision: 2)
        ])
        let rootSummary = try SVNXMLParser.parseDiffSummary(Data("<diff><paths><path kind=\"file\" item=\"added\">\(root.absoluteString)/snapshot/trunk/file.txt</path></paths></diff>".utf8))
        let rootDetails = try SVNRevisionDetails.combining(repositoryRootURL: root, entry: rootCopy, summary: rootSummary)
        try check(rootDetails.changes.first?.copyFromPath == "/trunk/file.txt", "repository-root copy source has a single leading slash")

        if let path = ProcessInfo.processInfo.environment["SVNDOCK_HISTORY_WC"] {
            try await realWorkingCopy(URL(fileURLWithPath: path))
        }
        print("History revision checks passed: fixed revisions, path validation, verbose log, copy/move ancestry and implicit descendants")
    }

    private static func realWorkingCopy(_ url: URL) async throws {
        let runner = ProcessRunner()
        let builder = try SVNCommandBuilder(executableURL: SVNExecutableLocator().locate())
        let copy = WorkingCopy(localPath: url)
        func run(_ operation: SVNOperationKind) async throws -> ProcessResult {
            let result = try await runner.run(builder.makeInvocation(for: operation, in: copy))
            try check(result.succeeded, result.standardErrorString)
            return result
        }
        let info = try await run(.info)
        let root = try SVNXMLParser.parseInfo(info.standardOutput).repositoryRootURL!
        for revision in [1, 2] {
            let log = try await run(.revisionLog(repositoryRoot: root, revision: revision))
            let summary = try await run(.revisionSummary(repositoryRoot: root, revision: revision))
            let details = try SVNRevisionDetails.combining(repositoryRootURL: root,
                entry: SVNXMLParser.parseLog(log.standardOutput)[0],
                summary: SVNXMLParser.parseDiffSummary(summary.standardOutput))
            try check(!details.changes.isEmpty, "real historical changed paths")
            var outputs: [String: String] = [:]
            for change in details.changes {
                let diff = try await run(.revisionDiff(repositoryRoot: root, revision: revision, change: change))
                outputs[change.path] = diff.standardOutputString
            }
            if revision == 2 {
                try check(outputs["/trunk/keep.txt"]?.contains("+after") == true, "modified file at revision after HEAD deletion")
                try check(outputs["/trunk/gone.txt"]?.contains("-removed content") == true, "deleted file preview")
                try check(outputs["/trunk/新增 @ 文件.txt"]?.contains("+新文件") == true, "Unicode added file preview")
                try check(outputs["/trunk/copied/child.txt"]?.contains("+edited copy") == true, "edited copied descendant compared with source")
                try check(outputs["/trunk/moved.txt"]?.contains("+moved edit") == true, "move preview")
                try check(outputs["/trunk/replaced.txt"]?.contains("-original replacement") == true && outputs["/trunk/replaced.txt"]?.contains("+new replacement") == true, "replacement contains both sides")
                try check(outputs["/trunk/binary.bin"]?.contains("Cannot display") == true, "binary revision output")
                try check(outputs["/trunk"]?.contains("svn:ignore") == true, "directory property-only diff")
            }
        }
        print("Real SVN revision previews passed, including r1, add/delete/replace/move/copy, properties, binary and paths deleted at HEAD")
    }
}
#endif
