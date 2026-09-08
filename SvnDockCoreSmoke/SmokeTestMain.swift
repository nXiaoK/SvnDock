#if SVNDOCK_SMOKE_TESTS
import Foundation
import SvnDockCore

@main
struct SvnDockCoreSmokeTestMain {
    static func main() async throws {
        try commandBuilderChecks()
        try parserChecks()
        try diffRegressionChecks()
        try await DiffCancellationSmoke.run()
        try await CoreRegressionSmoke.run()
        try await FinderQueueRegressionSmoke.run()
        try await HistoryRevisionSmoke.run()
        try await MissingDeletionSmoke.run()
        try locatorCheck()
        try await processRunnerCheck()
        try await LiveProgressSmoke.run()
        try await schedulerCheck()
        try await sharedStoreCheck()
        if let path = ProcessInfo.processInfo.environment["SVNDOCK_INTEGRATION_WC"],
           !path.isEmpty {
            try await realSVNWorkingCopyCheck(at: URL(fileURLWithPath: path, isDirectory: true))
            try await realSVNMissingAdditionCheck(at: URL(fileURLWithPath: path, isDirectory: true))
        }
        if let path = ProcessInfo.processInfo.environment["SVNDOCK_RESOLVE_WC"],
           !path.isEmpty {
            try await realSVNResolveCheck(at: URL(fileURLWithPath: path, isDirectory: true))
        }
        print("SvnDockCore smoke tests passed")
    }

    private static func commandBuilderChecks() throws {
        let root = URL(fileURLWithPath: "/tmp/svndock-smoke/wc", isDirectory: true)
        let workingCopy = WorkingCopy(localPath: root)
        let builder = try SVNCommandBuilder(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/svn")
        )
        let invocation = try builder.makeInvocation(
            for: .add(
                paths: ["-safe-because-after-terminator"],
                parents: false,
                force: false,
                depth: nil
            ),
            in: workingCopy
        )
        try check(
            Array(invocation.arguments.suffix(2)) == ["--", "-safe-because-after-terminator"],
            "path option terminator"
        )

        let commitMessage = "message stays out of argv; $() `"
        let commit = try builder.makeInvocation(
            for: .commit(paths: ["README.md"], message: commitMessage, keepLocks: false),
            in: workingCopy
        )
        try check(!commit.arguments.contains(commitMessage), "commit message argv privacy")
        try check(commit.standardInput == Data(commitMessage.utf8), "commit message stdin")
        let largePaths = (0..<60_372).map { "assets/file-\($0).txt" }
        let largeCommit = try builder.makeInvocation(
            for: .commit(paths: largePaths, message: commitMessage, keepLocks: false),
            in: workingCopy
        )
        try check(largeCommit.arguments.count < 10, "large commit bounded argv")
        try check(
            largeCommit.argumentFiles.first?.contents
                == Data((largePaths.map { "./" + $0 }.joined(separator: "\n") + "\n").utf8),
            "large commit preserves every target"
        )
        let specialCommit = try builder.makeInvocation(
            for: .commit(
                paths: ["-option", "测试 space@x.txt", "line\nbreak.txt", "carriage\rreturn.txt"],
                message: commitMessage,
                keepLocks: true
            ),
            in: workingCopy
        )
        try check(
            specialCommit.argumentFiles.first?.contents == Data("./-option\n./测试 space@x.txt@\n".utf8),
            "commit targets preserve Unicode, spaces, dash and peg escaping"
        )
        try check(
            Array(specialCommit.arguments.suffix(3)) == ["--", "line\nbreak.txt", "carriage\rreturn.txt"],
            "line breaks cannot inject extra file targets"
        )
        try check(specialCommit.arguments.contains("--no-unlock"), "commit preserves locks")

        let pegSafe = try builder.makeInvocation(
            for: .add(
                paths: ["notes/user@example.txt"],
                parents: false,
                force: false,
                depth: nil
            ),
            in: workingCopy
        )
        try check(pegSafe.arguments.last == "notes/user@example.txt@", "peg revision escaping")

        let unscheduleAdd = try builder.makeInvocation(
            for: .revert(
                paths: ["ImportedProject"],
                depth: .infinity
            ),
            in: workingCopy
        )
        try check(
            unscheduleAdd.arguments == [
                "revert", "--depth", "infinity", "--non-interactive",
                "--", "ImportedProject"
            ],
            "recursive revert for unscheduling additions"
        )
        try check(
            !unscheduleAdd.arguments.contains("--remove-added"),
            "ordinary additions omit remove-added; copied additions need separate preflight rejection"
        )

        let diffLiteral = try builder.makeInvocation(
            for: .diff(paths: ["notes/user@example.txt"]),
            in: workingCopy
        )
        try check(diffLiteral.arguments.last == "notes/user@example.txt", "diff @ literal")
        try check(
            diffLiteral.arguments.contains("--internal-diff"),
            "diff output remains unified"
        )

        let scopedStatus = try builder.makeInvocation(
            for: .status(SVNStatusOptions(
                includeIgnored: true,
                paths: ["notes/user@example.txt"]
            )),
            in: workingCopy
        )
        try check(scopedStatus.arguments.contains("--no-ignore"), "scoped status ignored rows")
        try check(
            scopedStatus.arguments.last == "notes/user@example.txt@",
            "scoped status peg revision escaping"
        )

        let legacyStatusOptions = try JSONDecoder().decode(
            SVNStatusOptions.self,
            from: Data(#"{"showRemoteUpdates":false,"includeIgnored":true}"#.utf8)
        )
        try check(legacyStatusOptions.paths.isEmpty, "legacy status options decoding")

        let log = try builder.makeInvocation(
            for: .log(paths: ["notes/user@example.txt"], limit: 25),
            in: workingCopy
        )
        try check(log.arguments.contains("--xml"), "log XML output")
        try check(
            log.arguments.contains("HEAD:1"),
            "working-copy log includes repository HEAD"
        )
        try check(log.arguments.last == "notes/user@example.txt@", "log peg revision escaping")

        let resolve = try builder.makeInvocation(
            for: .resolve(paths: ["notes/user@example.txt"], accept: .working),
            in: workingCopy
        )
        try check(resolve.arguments.contains("working"), "resolve conflict choice")
        try check(resolve.arguments.last == "notes/user@example.txt@", "resolve peg revision escaping")

        let setIgnore = try builder.makeInvocation(
            for: .setIgnore(path: ".", patterns: [".build", "*.tmp"]),
            in: workingCopy
        )
        try check(
            setIgnore.standardInput == Data(".build\n*.tmp\n".utf8),
            "ignore rules via stdin"
        )

        do {
            _ = try builder.makeInvocation(
                for: .diff(paths: ["../../escape"]),
                in: workingCopy
            )
            throw SmokeFailure("outside path was accepted")
        } catch is SVNCommandBuilderError {
            // Expected.
        }
    }

    private static func parserChecks() throws {
        let statusXML = """
        <status>
          <changelist name="urgent">
            <entry path="README.md">
              <wc-status item="modified" props="none" revision="7" tree-conflicted="true">
                <commit revision="6"><author>alice</author><date>2026-09-04T01:02:03.456Z</date></commit>
              </wc-status>
              <repos-status item="modified" props="none" />
            </entry>
          </changelist>
        </status>
        """
        let status = try SVNXMLParser.parseStatus(Data(statusXML.utf8))
        try check(status.count == 1, "status count")
        try check(status[0].status == .modified, "local status")
        try check(status[0].repositoryStatus == .modified, "repository status")
        try check(status[0].changelist == "urgent", "changelist")
        try check(status[0].isTreeConflicted, "tree conflict")

        let infoXML = """
        <info><entry kind="dir" path="." revision="9">
          <url>https://svn.example.test/repos/project/trunk</url>
          <repository><root>https://svn.example.test/repos</root><uuid>repo-id</uuid></repository>
          <wc-info><wcroot-abspath>/tmp/wc</wcroot-abspath><schedule>normal</schedule><depth>infinity</depth></wc-info>
        </entry></info>
        """
        let info = try SVNXMLParser.parseInfo(Data(infoXML.utf8))
        try check(info.kind == .directory, "info kind")
        try check(info.revision == 9, "info revision")
        try check(info.repositoryUUID == "repo-id", "repository UUID")

        let logXML = """
        <log>
          <logentry revision="11">
            <author>alice</author>
            <date>2026-09-04T02:03:04.123456Z</date>
            <msg>Fix Finder &amp; queue handling</msg>
          </logentry>
          <logentry revision="10"><msg></msg></logentry>
          <logentry revision="9"><msg>\nTitle\n\nBody\n</msg></logentry>
        </log>
        """
        let history = try SVNXMLParser.parseLog(Data(logXML.utf8))
        try check(history.map(\.revision) == [11, 10, 9], "log revisions")
        try check(history[0].author == "alice", "log author")
        try check(history[0].message == "Fix Finder & queue handling", "log message")
        try check(history[2].message == "\nTitle\n\nBody\n", "raw log message whitespace")

        let propertiesXML = """
        <properties><target path="."><property name="svn:ignore">.build
        *.tmp</property></target></properties>
        """
        let properties = try SVNXMLParser.parseProperties(Data(propertiesXML.utf8))
        try check(
            properties.first?.value(forProperty: "svn:ignore") == ".build\n*.tmp",
            "property value"
        )

        do {
            let encodedPropertyXML = """
            <properties><target path=".">
              <property name="svn:ignore" encoding="base64">AAE=</property>
            </target></properties>
            """
            _ = try SVNXMLParser.parseProperties(Data(encodedPropertyXML.utf8))
            throw SmokeFailure("opaque property encoding was accepted")
        } catch SVNXMLParserError.unsupportedPropertyEncoding("base64") {
            // Expected. Rewriting an opaque value would risk data loss.
        }

        let unifiedDiff = UnifiedDiffParser.parse("""
        --- Sources/App.swift (revision 4)
        +++ Sources/App.swift (working copy)
        @@ -8,2 +8,3 @@ struct App {
         unchanged
        -old value
        +new value
        +new line
        """)
        try check(
            unifiedDiff.rows.map(\.kind) == [.context, .change, .addition],
            "side-by-side diff alignment"
        )
        try check(
            unifiedDiff.rows[1].oldLineNumber == 9
                && unifiedDiff.rows[1].newLineNumber == 9,
            "side-by-side diff line numbers"
        )
    }

    private static func diffRegressionChecks() throws {
        let patch = """
        --- docs/API.md\t(revision 2)
        +++ docs/API.md\t(working copy)
        @@ -4,6 +4,9 @@
        \u{20}
         ---
        \u{20}
        +
        +新增中文说明
        +
         ## 中文
        \u{20}
         ### 目标
        @@ -106,7 +109,7 @@
         - `theme` (`light` / `dark`)
         - `lang` (例如 `zh` / `en`)
         - `ui_mode` (固定 `embedded`)
        -
        +替换后的说明
         示例：
         ```text
         https://pay.example.com/pay?user_id=123&theme=light&lang=zh&ui_mode=embedded
        """
        for text in [patch, patch.replacingOccurrences(of: "\n", with: "\r\n")] {
            let document = UnifiedDiffParser.parse(text)
            try check(document.hunks.count == 2, "LF/CRLF retain both screenshot hunks")
            try check(document.hunks.map { $0.rows.count } == [9, 7], "all screenshot rows retained")
            try check(document.hunks[0].rows[4].newLineNumber == 8, "inserted Chinese line number")
            try check(document.hunks[1].rows[3].kind == .change, "second hunk replacement")
            try check(document.hunks[1].rows.last?.oldLineNumber == 112, "old final file line number")
            try check(document.hunks[1].rows.last?.newLineNumber == 115, "new final file line number")
        }
        let replacement = UnifiedDiffParser.parse("@@ -1,2 +1,2 @@\n-old 1\n-old 2\n+new 1\n+new 2\n\\ No newline at end of file\n")
        let rows = replacement.hunks[0].unifiedRows
        try check(rows.map(\.kind) == [.deletion, .deletion, .addition, .addition], "unified replacement block order")
        try check(rows.map { $0.oldText ?? $0.newText ?? "" } == ["old 1", "old 2", "new 1", "new 2"], "unified content order")
        try check(rows.last?.newHasTrailingNewline == false, "unified no-newline annotation")
        let properties = "Property changes on: docs/API.md\n___________________________________________________________________\nAdded: svn:keywords\n## -0,0 +1 ##\n+Id\n"
        let combined = UnifiedDiffParser.parse(patch + "\n" + properties)
        try check(combined.hunks.count == 2 && combined.propertyChanges == properties, "text plus properties retained")
        let binary = "Cannot display: file marked as a binary type.\nsvn:mime-type = application/octet-stream\n"
        try check(UnifiedDiffParser.parse(binary).fallbackText == binary, "binary fallback retained")
        let truncated = "@@ -1 +1 @@\n-old\n+new\n@@ -9,2 +9,2 @@\n-only one line\n"
        let incomplete = UnifiedDiffParser.parse(truncated)
        try check(incomplete.hunks.isEmpty && incomplete.fallbackText == truncated, "truncated hunks use complete raw fallback")
        print("Diff regression checks passed: multiple hunks, file line numbers, CRLF, replacement ordering, newline markers, properties and binary fallback")
    }

    private static func locatorCheck() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SvnDockLocatorSmoke-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("svn", isDirectory: false)
        try check(
            FileManager.default.createFile(atPath: executable.path, contents: Data()),
            "create locator fixture"
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executable.path
        )

        let located = try SVNExecutableLocator(candidatePaths: [executable.path])
            .locate(environment: [:])
        try check(
            located.standardizedFileURL == executable.standardizedFileURL,
            "located executable"
        )
    }

    private static func processRunnerCheck() async throws {
        let input = Data("shell metacharacters are data: ; $() `\n".utf8)
        let result = try await ProcessRunner().run(ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            standardInput: input
        ))
        try check(result.succeeded, "process exit")
        try check(result.standardOutput == input, "stdin/stdout round trip")

        let fileInput = Data("temporary file\n".utf8)
        let combined = try await ProcessRunner().run(ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: ["", "-"],
            standardInput: input,
            argumentFiles: [ProcessArgumentFile(argumentIndex: 0, contents: fileInput)]
        ))
        try check(combined.succeeded && combined.standardOutput == fileInput + input, "argument file plus stdin")
        let filePath = try await ProcessRunner().run(ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", ""],
            argumentFiles: [ProcessArgumentFile(argumentIndex: 1, contents: fileInput)]
        ))
        let fileURL = URL(fileURLWithPath: filePath.standardOutputString)
        try check(filePath.succeeded && !filePath.standardOutputString.isEmpty, "temporary argument path")
        try check(
            !FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path),
            "argument file directory cleaned after exit"
        )

        for arguments in [Array(repeating: "x", count: 60_372), [String(repeating: "x", count: 2_000_000)]] {
            do {
                _ = try await ProcessRunner().run(ProcessInvocation(
                    executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                    arguments: arguments
                ))
                throw SmokeFailure("oversized process should fail before launch")
            } catch ProcessRunnerError.invalidInvocation {
                // Must return a Swift error rather than aborting the app.
            }
        }

        let temporaryRoot = FileManager.default.temporaryDirectory
        func argumentDirectories() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path)
                .filter { $0.hasPrefix("SvnDock-process-") })
        }
        let beforeFailure = try argumentDirectories()
        do {
            _ = try await ProcessRunner().run(ProcessInvocation(
                executableURL: temporaryRoot.appendingPathComponent("nonexistent-\(UUID().uuidString)"),
                arguments: [""],
                argumentFiles: [ProcessArgumentFile(argumentIndex: 0, contents: fileInput)]
            ))
            throw SmokeFailure("expected launch failure")
        } catch ProcessRunnerError.launchFailed {
            // Expected.
        }
        let afterFailure = try argumentDirectories()
        try check(afterFailure == beforeFailure, "argument file cleaned after launch failure")

        let marker = temporaryRoot.appendingPathComponent("SvnDock-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            try await ProcessRunner().run(ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf '%s' \"$1\" > \"$2\"; exec /bin/sleep 30", "fixture", "", marker.path],
                argumentFiles: [ProcessArgumentFile(argumentIndex: 3, contents: fileInput)]
            ))
        }
        defer { task.cancel() }
        var cancelledFilePath = ""
        for _ in 0..<200 {
            cancelledFilePath = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
            if !cancelledFilePath.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do {
            _ = try await task.value
            throw SmokeFailure("expected cancelled process")
        } catch is CancellationError {
            // Expected.
        }
        try check(!cancelledFilePath.isEmpty, "cancel fixture launched")
        try check(
            !FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: cancelledFilePath).deletingLastPathComponent().path
            ),
            "argument file cleaned after cancellation"
        )
    }

    private static func schedulerCheck() async throws {
        let scheduler = WorkingCopyOperationScheduler()
        let probe = SmokeConcurrencyProbe()
        let id = UUID()

        async let first: Void = scheduler.enqueue(for: id) {
            await probe.perform()
        }
        async let second: Void = scheduler.enqueue(for: id) {
            await probe.perform()
        }
        _ = try await (first, second)

        let maximum = await probe.maximum
        try check(maximum == 1, "per-working-copy serialization")
    }

    private static func sharedStoreCheck() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SvnDockSmoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try FinderSharedStore(directoryURL: directory)
        let workingCopy = WorkingCopy(
            name: "Smoke",
            localPath: URL(fileURLWithPath: "/tmp/svndock-smoke", isDirectory: true)
        )
        _ = try await store.register(workingCopy)
        let roots = try await store.loadRegisteredRoots()
        try check(roots.roots.map(\.id) == [workingCopy.id], "registered roots round trip")

        let badgeJSON = """
        {"schemaVersion":1,"generatedAt":"2026-09-04T01:02:03.456Z","entries":{"/tmp/svndock-smoke/a":"modified"}}
        """
        try Data(badgeJSON.utf8).write(
            to: directory.appendingPathComponent(FinderSharedSchema.badgeSnapshotFileName),
            options: .atomic
        )
        let badges = try await store.loadBadgeSnapshot()
        try check(badges.entries["/tmp/svndock-smoke/a"] == .modified, "fractional badge date")

        // Two independent actors must merge per-working-copy badge slices
        // under the filesystem lock instead of overwriting the whole cache.
        let secondStore = try FinderSharedStore(directoryURL: directory)
        let firstBadgeCopy = WorkingCopy(
            name: "Badge A",
            localPath: URL(fileURLWithPath: "/tmp/svndock-smoke-a", isDirectory: true)
        )
        let secondBadgeCopy = WorkingCopy(
            name: "Badge B",
            localPath: URL(fileURLWithPath: "/tmp/svndock-smoke-b", isDirectory: true)
        )
        _ = try await store.register(firstBadgeCopy)
        _ = try await store.register(secondBadgeCopy)
        async let firstBadgeSlice: Void = store.replaceBadgeEntries(
            forWorkingCopyID: firstBadgeCopy.id,
            underWorkingCopyRoot: "/tmp/svndock-smoke-a",
            with: ["/tmp/svndock-smoke-a/file": .added]
        )
        async let secondBadgeSlice: Void = secondStore.replaceBadgeEntries(
            forWorkingCopyID: secondBadgeCopy.id,
            underWorkingCopyRoot: "/tmp/svndock-smoke-b",
            with: ["/tmp/svndock-smoke-b/file": .conflicted]
        )
        _ = try await (firstBadgeSlice, secondBadgeSlice)
        let mergedBadges = try await store.loadBadgeSnapshot().entries
        try check(
            mergedBadges["/tmp/svndock-smoke-a/file"] == .added
                && mergedBadges["/tmp/svndock-smoke-b/file"] == .conflicted,
            "cross-process-safe badge slice merge"
        )

        let parentCopy = WorkingCopy(
            name: "Nested parent",
            localPath: URL(fileURLWithPath: "/tmp/svndock-nested", isDirectory: true)
        )
        let childCopy = WorkingCopy(
            name: "Nested child",
            localPath: URL(fileURLWithPath: "/tmp/svndock-nested/external", isDirectory: true)
        )
        _ = try await store.register(parentCopy)
        _ = try await store.register(childCopy)
        try await store.replaceBadgeEntries(
            forWorkingCopyID: childCopy.id,
            underWorkingCopyRoot: childCopy.localPath.path,
            with: ["/tmp/svndock-nested/external/child.txt": .modified]
        )
        try await store.replaceBadgeEntries(
            forWorkingCopyID: parentCopy.id,
            underWorkingCopyRoot: parentCopy.localPath.path,
            with: ["/tmp/svndock-nested/parent.txt": .added]
        )
        let nestedBadges = try await store.loadBadgeSnapshot().entries
        try check(
            nestedBadges["/tmp/svndock-nested/parent.txt"] == .added
                && nestedBadges["/tmp/svndock-nested/external/child.txt"] == .modified,
            "parent badge refresh preserves nested working-copy slice"
        )

        // Once the child is unregistered, a parent refresh owns that former
        // subtree. A delayed child cleanup must not erase the newer parent
        // result.
        _ = try await store.unregister(id: childCopy.id)
        try await store.replaceBadgeEntries(
            forWorkingCopyID: parentCopy.id,
            underWorkingCopyRoot: parentCopy.localPath.path,
            with: [
                "/tmp/svndock-nested/parent.txt": .added,
                "/tmp/svndock-nested/external/child.txt": .unversioned
            ]
        )
        try await store.removeBadgeEntries(
            forUnregisteredWorkingCopyID: childCopy.id,
            underWorkingCopyRoot: childCopy.localPath.path
        )
        let postCleanupSnapshot = try await store.loadBadgeSnapshot()
        try check(
            postCleanupSnapshot.entries["/tmp/svndock-nested/external/child.txt"]
                == .unversioned,
            "delayed child cleanup preserves newer parent-owned badge"
        )
        try check(
            postCleanupSnapshot.entryOwners?["/tmp/svndock-nested/external/child.txt"]
                == parentCopy.id,
            "badge snapshot records owning working-copy UUID"
        )

        // Re-registering the same path with a new UUID invalidates an older
        // Agent writer, even if it was already waiting for the badge lock.
        let replacementCopy = WorkingCopy(
            name: "Replacement",
            localPath: URL(fileURLWithPath: "/tmp/svndock-replaced", isDirectory: true)
        )
        let staleCopy = WorkingCopy(
            name: "Stale",
            localPath: replacementCopy.localPath
        )
        _ = try await store.register(staleCopy)
        try await store.replaceBadgeEntries(
            forWorkingCopyID: staleCopy.id,
            underWorkingCopyRoot: staleCopy.localPath.path,
            with: ["/tmp/svndock-replaced/file.txt": .modified]
        )
        _ = try await store.register(replacementCopy)
        try await store.removeBadgeEntries(
            forUnregisteredWorkingCopyID: staleCopy.id,
            underWorkingCopyRoot: staleCopy.localPath.path
        )
        let clearedStaleSnapshot = try await store.loadBadgeSnapshot()
        try check(
            clearedStaleSnapshot.entries["/tmp/svndock-replaced/file.txt"] == nil,
            "same-path registration cleanup removes retired UUID badges"
        )
        do {
            try await store.replaceBadgeEntries(
                forWorkingCopyID: staleCopy.id,
                underWorkingCopyRoot: staleCopy.localPath.path,
                with: ["/tmp/svndock-replaced/file.txt": .modified]
            )
            throw SmokeFailure("stale working-copy UUID published badges")
        } catch FinderSharedStoreError.badgeRootNotRegistered {
            // Expected.
        }
        try await store.replaceBadgeEntries(
            forWorkingCopyID: replacementCopy.id,
            underWorkingCopyRoot: replacementCopy.localPath.path,
            with: ["/tmp/svndock-replaced/file.txt": .added]
        )
        try await store.removeBadgeEntries(
            forUnregisteredWorkingCopyID: staleCopy.id,
            underWorkingCopyRoot: staleCopy.localPath.path
        )
        let replacementSnapshot = try await store.loadBadgeSnapshot()
        try check(
            replacementSnapshot.entries["/tmp/svndock-replaced/file.txt"]
                == .added,
            "stale cleanup preserves replacement UUID badge"
        )

        // Corrupt badge data is disposable, but recovering one root must not
        // invent exact states or freshness for roots which have not rescanned.
        let snapshotURL = directory.appendingPathComponent(FinderSharedSchema.badgeSnapshotFileName)
        let corruptBadgeData = Data("{\"schemaVersion\":1,\"entries\":".utf8)
        try corruptBadgeData.write(to: snapshotURL, options: .atomic)
        try await store.replaceBadgeEntries(
            forWorkingCopyID: parentCopy.id,
            underWorkingCopyRoot: parentCopy.localPath.path,
            with: ["/tmp/svndock-nested/parent.txt": .conflicted],
            directEntries: ["/tmp/svndock-nested/parent.txt": .conflicted]
        )
        let recoveredSnapshot = try await store.loadBadgeSnapshot()
        try check(recoveredSnapshot.entries == ["/tmp/svndock-nested/parent.txt": .conflicted],
                  "corrupt badge recovery publishes only the refreshed root")
        try check(recoveredSnapshot.entryOwners?["/tmp/svndock-nested/parent.txt"] == parentCopy.id
                  && recoveredSnapshot.directEntries?["/tmp/svndock-nested/parent.txt"] == .conflicted,
                  "corrupt badge recovery retains authoritative ownership and direct state")
        try check(Set(recoveredSnapshot.perRootUpdatedAt?.keys.map { $0 } ?? []) == [parentCopy.localPath.path],
                  "corrupt badge recovery leaves other roots unknown")
        let quarantinedBadges = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("badge-snapshot.corrupt-") }
        try check(quarantinedBadges.count == 1, "one corrupt badge snapshot is quarantined")
        let quarantinedData = try Data(contentsOf: quarantinedBadges[0])
        try check(quarantinedData == corruptBadgeData,
                  "corrupt badge data is quarantined intact")
        try await secondStore.replaceBadgeEntries(forWorkingCopyID: secondBadgeCopy.id,
            underWorkingCopyRoot: secondBadgeCopy.localPath.path,
            with: ["/tmp/svndock-smoke-b/file": .added])
        let subsequentSnapshot = try await store.loadBadgeSnapshot()
        try check(subsequentSnapshot.entries["/tmp/svndock-nested/parent.txt"] == .conflicted
                  && subsequentSnapshot.entries["/tmp/svndock-smoke-b/file"] == .added,
                  "another root refresh merges after corrupt cache recovery")

        // A newer schema must be rejected before decoding fields whose shape
        // this writer does not understand, and its file must remain intact.
        let futureBadgeData = Data("{\"schemaVersion\":99,\"entries\":false}".utf8)
        try futureBadgeData.write(to: snapshotURL, options: .atomic)
        do {
            try await store.replaceBadgeEntries(forWorkingCopyID: parentCopy.id,
                underWorkingCopyRoot: parentCopy.localPath.path, with: [:])
            throw SmokeFailure("future badge schema was overwritten")
        } catch FinderSharedStoreError.unsupportedSchemaVersion(99) {
            // Expected.
        }
        let retainedFutureData = try Data(contentsOf: snapshotURL)
        try check(retainedFutureData == futureBadgeData, "future badge data remains intact")

        try corruptBadgeData.write(to: snapshotURL, options: .atomic)
        try await store.removeBadgeEntries(forUnregisteredWorkingCopyID: childCopy.id,
            underWorkingCopyRoot: childCopy.localPath.path)
        let clearedCorruptSnapshot = try await store.loadBadgeSnapshot()
        try check(clearedCorruptSnapshot.entries.isEmpty
                  && clearedCorruptSnapshot.perRootUpdatedAt?.isEmpty == true,
                  "unregister recovery never marks unscanned roots fresh")

        let command = FinderCommand(
            kind: .diff,
            paths: ["/tmp/svndock-smoke/a"],
            workingCopyRoot: "/tmp/svndock-smoke"
        )
        let commandURL = try await store.enqueue(command)
        try check(
            commandURL.lastPathComponent == "\(command.id.uuidString.lowercased()).json",
            "lowercase command filename"
        )
        let commands = try await store.loadCommands()
        try check(commands.first?.source == "finder-extension", "Finder command source")

        // A malformed sibling must not prevent the opaque URL request from
        // resolving its one exact queue item.
        let queueURL = directory.appendingPathComponent(
            FinderSharedSchema.commandQueueDirectoryName,
            isDirectory: true
        )
        try Data("not-json".utf8).write(
            to: queueURL.appendingPathComponent("malformed.json"),
            options: .atomic
        )
        let commandsWithMalformedSibling = try await store.loadCommands()
        try check(
            commandsWithMalformedSibling.map(\.id) == [command.id],
            "skip malformed Finder command"
        )
        let loadedCommand = try await store.loadCommand(id: command.id)
        try check(loadedCommand?.id == command.id, "load exact Finder command")

        let coordinator = try FinderCommandQueueCoordinator(directoryURL: directory)
        let agentClaim = try await coordinator.claimCommand(id: command.id, as: .agent)
        try check(agentClaim != nil, "Agent atomically claims Finder command")
        if let agentClaim {
            try await coordinator.handoffToApplication(agentClaim)
        }
        let handedOffLocation = try await coordinator.location(of: command.id)
        try check(
            handedOffLocation == .applicationInbox,
            "Agent atomically hands command to App inbox"
        )
        let appClaim = try await coordinator.claimCommand(id: command.id, as: .application)
        try check(appClaim?.owner == .application, "App claims handed-off command")
        if let appClaim {
            let awaiting = try await coordinator.markAwaitingUser(appClaim)
            try await coordinator.acknowledge(awaiting, outcome: .cancelled)
        }
        let completedLocation = try await coordinator.location(of: command.id)
        try check(
            completedLocation == .completed(.cancelled),
            "terminal Finder command receipt"
        )

        // A duplicate App-inbox file can appear after the Agent has claimed
        // the pending copy. Identical payloads collapse into the durable inbox
        // request instead of producing an uncertain state or losing both.
        let duplicateHandoff = FinderCommand(
            kind: .commit,
            paths: ["/tmp/svndock-smoke/a"],
            workingCopyRoot: "/tmp/svndock-smoke"
        )
        _ = try await store.enqueue(duplicateHandoff)
        if let claim = try await coordinator.claimCommand(
            id: duplicateHandoff.id,
            as: .agent
        ) {
            let processingDirectory = directory.appendingPathComponent(
                "command-processing/agent",
                isDirectory: true
            )
            let processingURL = try FileManager.default.contentsOfDirectory(
                at: processingDirectory,
                includingPropertiesForKeys: nil
            ).first.map { $0 }
            guard let processingURL else {
                throw SmokeFailure("missing Agent claim file")
            }
            let inboxURL = directory
                .appendingPathComponent("command-app-inbox", isDirectory: true)
                .appendingPathComponent(
                    "\(duplicateHandoff.id.uuidString.lowercased()).json"
                )
            try FileManager.default.copyItem(at: processingURL, to: inboxURL)
            try await coordinator.handoffToApplication(claim)
        } else {
            throw SmokeFailure("Agent did not claim duplicate handoff request")
        }
        let duplicateHandoffLocation = try await coordinator.location(
            of: duplicateHandoff.id
        )
        try check(
            duplicateHandoffLocation == .applicationInbox,
            "identical handoff duplicate collapses to App inbox"
        )
        if let claim = try await coordinator.claimCommand(
            id: duplicateHandoff.id,
            as: .application
        ) {
            try await coordinator.acknowledge(claim, outcome: .cancelled)
        } else {
            throw SmokeFailure("App did not claim collapsed handoff request")
        }

        let conflictingHandoff = FinderCommand(
            kind: .commit,
            paths: ["/tmp/svndock-smoke/a"],
            workingCopyRoot: "/tmp/svndock-smoke"
        )
        _ = try await store.enqueue(conflictingHandoff)
        if let claim = try await coordinator.claimCommand(
            id: conflictingHandoff.id,
            as: .agent
        ) {
            let conflict = FinderCommand(
                id: conflictingHandoff.id,
                kind: .revert,
                paths: conflictingHandoff.paths,
                workingCopyRoot: conflictingHandoff.workingCopyRoot,
                createdAt: conflictingHandoff.createdAt
            )
            _ = try await store.enqueue(conflict)
            let fileName = conflictingHandoff.id.uuidString.lowercased() + ".json"
            try FileManager.default.moveItem(
                at: queueURL.appendingPathComponent(fileName),
                to: directory
                    .appendingPathComponent("command-app-inbox", isDirectory: true)
                    .appendingPathComponent(fileName)
            )
            let disposition = try await coordinator.handoffToApplication(claim)
            try check(
                disposition == .quarantinedConflict,
                "conflicting handoff is atomically quarantined"
            )
        } else {
            throw SmokeFailure("Agent did not claim conflicting handoff request")
        }
        let conflictingHandoffLocation = try await coordinator.location(
            of: conflictingHandoff.id
        )
        try check(
            conflictingHandoffLocation == .uncertain,
            "conflicting handoff cannot be recovered into an executable queue"
        )

        let duplicateRelease = FinderCommand(
            kind: .update,
            paths: ["/tmp/svndock-smoke"],
            workingCopyRoot: "/tmp/svndock-smoke"
        )
        _ = try await store.enqueue(duplicateRelease)
        if let claim = try await coordinator.claimCommand(
            id: duplicateRelease.id,
            as: .agent
        ) {
            _ = try await store.enqueue(duplicateRelease)
            let disposition = try await coordinator.releaseWithoutExecution(claim)
            try check(
                disposition == .collapsedIdenticalDuplicate,
                "identical release duplicate collapses safely"
            )
        } else {
            throw SmokeFailure("Agent did not claim duplicate release request")
        }
        let duplicateReleaseLocation = try await coordinator.location(
            of: duplicateRelease.id
        )
        try check(
            duplicateReleaseLocation == .pending,
            "collapsed release preserves one pending request"
        )

        let conflictingRelease = FinderCommand(
            kind: .update,
            paths: ["/tmp/svndock-smoke"],
            workingCopyRoot: "/tmp/svndock-smoke"
        )
        _ = try await store.enqueue(conflictingRelease)
        if let claim = try await coordinator.claimCommand(
            id: conflictingRelease.id,
            as: .agent
        ) {
            let conflict = FinderCommand(
                id: conflictingRelease.id,
                kind: .cleanup,
                paths: conflictingRelease.paths,
                workingCopyRoot: conflictingRelease.workingCopyRoot,
                createdAt: conflictingRelease.createdAt
            )
            _ = try await store.enqueue(conflict)
            let disposition = try await coordinator.releaseWithoutExecution(claim)
            try check(
                disposition == .quarantinedConflict,
                "conflicting release duplicate is quarantined"
            )
        } else {
            throw SmokeFailure("Agent did not claim conflicting release request")
        }
        let conflictingReleaseLocation = try await coordinator.location(
            of: conflictingRelease.id
        )
        try check(
            conflictingReleaseLocation == .uncertain,
            "uncertain state takes precedence over a conflicting pending copy"
        )

        // Conflicting unowned copies must be detected before either consumer
        // receives a capability. Stage the second JSON through the public
        // store so both payloads use the production date codec.
        let preclaimConflict = FinderCommand(
            kind: .commit,
            paths: ["/tmp/svndock-smoke/a"],
            workingCopyRoot: "/tmp/svndock-smoke"
        )
        _ = try await store.enqueue(preclaimConflict)
        let stagingDirectory = directory.appendingPathComponent(
            "preclaim-conflict-staging",
            isDirectory: true
        )
        let stagingStore = try FinderSharedStore(directoryURL: stagingDirectory)
        let preclaimConflictCopy = FinderCommand(
            id: preclaimConflict.id,
            kind: .revert,
            paths: preclaimConflict.paths,
            workingCopyRoot: preclaimConflict.workingCopyRoot,
            createdAt: preclaimConflict.createdAt
        )
        let stagedURL = try await stagingStore.enqueue(preclaimConflictCopy)
        let preclaimConflictName = preclaimConflict.id.uuidString.lowercased() + ".json"
        try FileManager.default.copyItem(
            at: stagedURL,
            to: directory
                .appendingPathComponent("command-app-inbox", isDirectory: true)
                .appendingPathComponent(preclaimConflictName)
        )
        do {
            _ = try await coordinator.claimCommand(
                id: preclaimConflict.id,
                as: .application
            )
            throw SmokeFailure("conflicting pre-claim copies were accepted")
        } catch FinderCommandQueueError.conflictingCommandCopies {
            // Expected.
        }
        let preclaimConflictLocation = try await coordinator.location(
            of: preclaimConflict.id
        )
        try check(
            preclaimConflictLocation == .uncertain,
            "conflicting unowned copies fail closed before claim"
        )

        // Also cover a crash before handoff is called at all: recovery must
        // notice the conflicting App inbox and quarantine the Agent claim,
        // never release it back behind the conflicting request.
        let recoveryConflict = FinderCommand(
            kind: .commit,
            paths: ["/tmp/svndock-smoke/a"],
            workingCopyRoot: "/tmp/svndock-smoke"
        )
        _ = try await store.enqueue(recoveryConflict)
        guard try await coordinator.claimCommand(
            id: recoveryConflict.id,
            as: .agent
        ) != nil else {
            throw SmokeFailure("Agent did not claim pre-handoff recovery request")
        }
        let recoveryConflictCopy = FinderCommand(
            id: recoveryConflict.id,
            kind: .revert,
            paths: recoveryConflict.paths,
            workingCopyRoot: recoveryConflict.workingCopyRoot,
            createdAt: recoveryConflict.createdAt
        )
        _ = try await store.enqueue(recoveryConflictCopy)
        let recoveryConflictName = recoveryConflict.id.uuidString.lowercased() + ".json"
        try FileManager.default.moveItem(
            at: queueURL.appendingPathComponent(recoveryConflictName),
            to: directory
                .appendingPathComponent("command-app-inbox", isDirectory: true)
                .appendingPathComponent(recoveryConflictName)
        )

        let uncertainCommand = FinderCommand(
            kind: .cleanup,
            paths: ["/tmp/svndock-smoke"],
            workingCopyRoot: "/tmp/svndock-smoke"
        )
        _ = try await store.enqueue(uncertainCommand)
        if let claim = try await coordinator.claimCommand(
            id: uncertainCommand.id,
            as: .agent
        ) {
            _ = try await coordinator.markExecuting(claim)
        }
        let lease = try await coordinator.acquireConsumerLease(for: .agent)
        try check(lease != nil, "Agent singleton lease")
        if let lease {
            let recovery = try await coordinator.recoverOrphanedClaims(
                for: .agent,
                lease: lease
            )
            try check(
                recovery.quarantined == 2,
                "unknown execution and pre-handoff conflict quarantined"
            )
        }
        let uncertainLocation = try await coordinator.location(of: uncertainCommand.id)
        try check(
            uncertainLocation == .uncertain,
            "executing command is never blindly replayed (found \(uncertainLocation))"
        )
        let recoveryConflictLocation = try await coordinator.location(
            of: recoveryConflict.id
        )
        try check(
            recoveryConflictLocation == .uncertain,
            "pre-handoff crash conflict is never released behind App inbox"
        )
    }

    private static func realSVNWorkingCopyCheck(at root: URL) async throws {
        let executable = try SVNExecutableLocator().locate()
        let builder = try SVNCommandBuilder(executableURL: executable)
        let runner = ProcessRunner()
        let workingCopy = WorkingCopy(localPath: root)

        let infoResult = try await runner.run(
            builder.makeInvocation(for: .info, in: workingCopy)
        )
        try check(infoResult.succeeded, "real svn info")
        let info = try SVNXMLParser.parseInfo(infoResult.standardOutput)
        try check(
            info.workingCopyRootURL?.standardizedFileURL == root.standardizedFileURL,
            "real svn wc root"
        )

        let pendingDirectory = root.appendingPathComponent(
            "unschedule-\(UUID().uuidString)",
            isDirectory: true
        )
        let pendingFile = pendingDirectory.appendingPathComponent("kept-on-disk.txt")
        try FileManager.default.createDirectory(
            at: pendingDirectory,
            withIntermediateDirectories: false
        )
        try Data("keep this file\n".utf8).write(to: pendingFile, options: .atomic)

        let addPendingResult = try await runner.run(
            builder.makeInvocation(
                for: .add(
                    paths: [pendingDirectory.path],
                    parents: false,
                    force: true,
                    depth: .infinity
                ),
                in: workingCopy
            )
        )
        try check(addPendingResult.succeeded, "real svn add pending directory")
        let pendingStatusResult = try await runner.run(
            builder.makeInvocation(
                for: .status(SVNStatusOptions(
                    depth: .empty,
                    paths: [pendingDirectory.path]
                )),
                in: workingCopy
            )
        )
        let pendingStatus = try SVNXMLParser.parseStatus(
            pendingStatusResult.standardOutput,
            workingCopyURL: root
        )
        try check(
            pendingStatus.contains {
                $0.status == .added
                    && $0.fileURL(relativeTo: workingCopy).standardizedFileURL
                        == pendingDirectory.standardizedFileURL
            },
            "real svn pending directory is scheduled for addition"
        )

        let unscheduleResult = try await runner.run(
            builder.makeInvocation(
                for: .revert(
                    paths: [pendingDirectory.path],
                    depth: .infinity
                ),
                in: workingCopy
            )
        )
        try check(unscheduleResult.succeeded, "real svn unschedule pending directory")
        try check(
            FileManager.default.fileExists(atPath: pendingDirectory.path)
                && FileManager.default.fileExists(atPath: pendingFile.path),
            "real svn unschedule preserves added files on disk"
        )
        let unversionedStatusResult = try await runner.run(
            builder.makeInvocation(
                for: .status(SVNStatusOptions(
                    depth: .empty,
                    paths: [pendingDirectory.path]
                )),
                in: workingCopy
            )
        )
        let unversionedStatus = try SVNXMLParser.parseStatus(
            unversionedStatusResult.standardOutput,
            workingCopyURL: root
        )
        try check(
            unversionedStatus.contains {
                $0.status == .unversioned
                    && $0.fileURL(relativeTo: workingCopy).standardizedFileURL
                        == pendingDirectory.standardizedFileURL
            },
            "real svn unschedule returns directory to unversioned state"
        )

        let file = root.appendingPathComponent("integration@example.txt")
        try Data("first version\n".utf8).write(to: file, options: .atomic)

        let addResult = try await runner.run(
            builder.makeInvocation(
                for: .add(
                    paths: [file.path],
                    parents: false,
                    force: false,
                    depth: nil
                ),
                in: workingCopy
            )
        )
        try check(addResult.succeeded, "real svn add @ filename")

        let commitResult = try await runner.run(
            builder.makeInvocation(
                for: .commit(
                    paths: [file.path],
                    message: "SvnDock integration smoke",
                    keepLocks: false
                ),
                in: workingCopy
            )
        )
        try check(commitResult.succeeded, "real svn commit via stdin")

        // A missing scheduled addition must not prevent an unrelated selected
        // file from being committed, nor be silently reverted by that commit.
        let missing = root.appendingPathComponent("missing-add.txt")
        let selected = root.appendingPathComponent("-selected 测试@x.txt")
        try Data("missing soon".utf8).write(to: missing)
        try Data("selected file".utf8).write(to: selected)
        let addSelection = try await runner.run(builder.makeInvocation(
            for: .add(paths: [missing.path, selected.path], parents: false, force: false, depth: nil),
            in: workingCopy
        ))
        try check(addSelection.succeeded, "real svn add commit selection fixtures: \(addSelection.standardErrorString)")
        try FileManager.default.removeItem(at: missing)
        let missingCommit = try await runner.run(builder.makeInvocation(
            for: .commit(paths: [missing.path], message: "missing file", keepLocks: false),
            in: workingCopy
        ))
        try check(
            !missingCommit.succeeded && missingCommit.standardErrorString.contains("E155010"),
            "real svn reproduces missing addition failure without crashing"
        )
        let selectedCommit = try await runner.run(builder.makeInvocation(
            for: .commit(paths: [selected.path], message: "只提交选中的文件", keepLocks: false),
            in: workingCopy
        ))
        try check(selectedCommit.succeeded, "real svn selected special filename: \(selectedCommit.standardErrorString)")
        let selectedLog = try await runner.run(builder.makeInvocation(
            for: .log(paths: [selected.path], limit: 1), in: workingCopy
        ))
        let selectedHistory = try SVNXMLParser.parseLog(selectedLog.standardOutput)
        try check(selectedHistory.first?.message == "只提交选中的文件", "real svn UTF-8 commit message")
        let selectionStatus = try await runner.run(builder.makeInvocation(
            for: .status(SVNStatusOptions()), in: workingCopy
        ))
        let selectionEntries = try SVNXMLParser.parseStatus(selectionStatus.standardOutput, workingCopyURL: root)
        try check(
            selectionEntries.contains { $0.path.hasSuffix("missing-add.txt") && $0.status == .missing },
            "single file commit leaves missing addition unchanged"
        )
        let unscheduleMissing = try await runner.run(builder.makeInvocation(
            for: .revert(paths: [missing.path], depth: .empty), in: workingCopy
        ))
        try check(unscheduleMissing.succeeded, "clean disposable missing addition fixture")

        // Opt-in stress coverage: only use a disposable repository, as with
        // SVNDOCK_INTEGRATION_WC itself. Normal smoke runs create no SVN data.
        if let value = ProcessInfo.processInfo.environment["SVNDOCK_LARGE_COMMIT_COUNT"],
           let count = Int(value), (4_097...100_000).contains(count) {
            let directory = root.appendingPathComponent("large-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            var paths = [directory.path]
            for index in 0..<count {
                // Keep directory fan-out representative of a source tree.
                // On case-insensitive macOS volumes SVN scans a file's parent
                // to verify its case; one flat 60k-file directory makes that
                // scan quadratic independently of the process argv transport.
                let group = directory.appendingPathComponent("group-\(index / 100)", isDirectory: true)
                if index % 100 == 0 {
                    try FileManager.default.createDirectory(at: group, withIntermediateDirectories: false)
                    paths.append(group.path)
                }
                let file = group.appendingPathComponent("file-\(index).txt")
                try Data("\(index)\n".utf8).write(to: file)
                paths.append(file.path)
            }
            let largeAdd = try await runner.run(builder.makeInvocation(
                for: .add(paths: [directory.path], parents: false, force: false, depth: .infinity),
                in: workingCopy
            ))
            try check(largeAdd.succeeded, "real svn large add")
            let previousLog = try await runner.run(builder.makeInvocation(
                for: .log(paths: [], limit: 1), in: workingCopy
            ))
            let previous = try SVNXMLParser.parseLog(previousLog.standardOutput).first?.revision ?? 0
            let largeCommit = try await runner.run(builder.makeInvocation(
                for: .commit(paths: paths, message: "large atomic commit", keepLocks: false),
                in: workingCopy
            ))
            try check(largeCommit.succeeded, "real svn large commit: \(largeCommit.standardErrorString)")
            let largeLog = try await runner.run(builder.makeInvocation(
                for: .log(paths: [directory.path], limit: 1), in: workingCopy
            ))
            let revision = try SVNXMLParser.parseLog(largeLog.standardOutput).first
            try check(revision?.message == "large atomic commit", "large commit log message")
            try check(revision?.revision == previous + 1, "large commit creates exactly one revision")
            let largeStatus = try await runner.run(builder.makeInvocation(
                for: .status(SVNStatusOptions(paths: [directory.path])), in: workingCopy
            ))
            let largeEntries = try SVNXMLParser.parseStatus(largeStatus.standardOutput, workingCopyURL: root)
            try check(largeStatus.succeeded && largeEntries.isEmpty, "all large commit targets are clean")
            print("Real SVN commit passed: \(count) files in one transaction")
        }

        let logResult = try await runner.run(
            builder.makeInvocation(
                for: .log(paths: [file.path], limit: 5),
                in: workingCopy
            )
        )
        try check(logResult.succeeded, "real svn log")
        let history = try SVNXMLParser.parseLog(logResult.standardOutput)
        try check(
            history.contains(where: { $0.message == "SvnDock integration smoke" }),
            "real svn log parse"
        )

        let propertiesResult = try await runner.run(
            builder.makeInvocation(for: .properties(paths: ["."]), in: workingCopy)
        )
        try check(propertiesResult.succeeded, "real svn proplist")
        _ = try SVNXMLParser.parseProperties(propertiesResult.standardOutput)

        let setIgnoreResult = try await runner.run(
            builder.makeInvocation(
                for: .setIgnore(path: ".", patterns: ["*.tmp"]),
                in: workingCopy
            )
        )
        try check(setIgnoreResult.succeeded, "real svn propset ignore via stdin")
        let ignoredFile = root.appendingPathComponent("smoke-ignore.tmp")
        try Data("ignored\n".utf8).write(to: ignoredFile, options: .atomic)
        let ignoredStatusResult = try await runner.run(
            builder.makeInvocation(
                for: .status(SVNStatusOptions()),
                in: workingCopy
            )
        )
        let ignoredStatus = try SVNXMLParser.parseStatus(
            ignoredStatusResult.standardOutput,
            workingCopyURL: root
        )
        try check(
            !ignoredStatus.contains(where: { $0.path.hasSuffix("smoke-ignore.tmp") }),
            "real svn ignore effect"
        )
        let revertIgnoreResult = try await runner.run(
            builder.makeInvocation(
                for: .revert(paths: ["."], depth: .empty),
                in: workingCopy
            )
        )
        try check(revertIgnoreResult.succeeded, "real svn revert root property only")

        try Data("first version\nsecond version\n".utf8).write(to: file, options: .atomic)
        let statusResult = try await runner.run(
            builder.makeInvocation(
                for: .status(SVNStatusOptions()),
                in: workingCopy
            )
        )
        try check(statusResult.succeeded, "real svn status")
        let entries = try SVNXMLParser.parseStatus(
            statusResult.standardOutput,
            workingCopyURL: root
        )
        try check(entries.contains(where: { $0.status == .modified }), "real modified parse")

        let diffResult = try await runner.run(
            builder.makeInvocation(for: .diff(paths: [file.path]), in: workingCopy)
        )
        try check(
            diffResult.succeeded,
            "real svn diff: \(diffResult.standardErrorString)"
        )
        try check(diffResult.standardOutputString.contains("second version"), "real diff content")

        let revertResult = try await runner.run(
            builder.makeInvocation(
                for: .revert(paths: [file.path], depth: .empty),
                in: workingCopy
            )
        )
        try check(revertResult.succeeded, "real svn revert")
    }

    private static func realSVNMissingAdditionCheck(at root: URL) async throws {
        let executable = try SVNExecutableLocator().locate()
        let runner = ProcessRunner()
        let builder = try SVNCommandBuilder(executableURL: executable)
        let undo = try SVNAdditionUndo(executableURL: executable, runner: runner)
        let workingCopy = WorkingCopy(localPath: root)
        func run(_ operation: SVNOperationKind) async throws -> ProcessResult {
            let result = try await runner.run(builder.makeInvocation(for: operation, in: workingCopy))
            try check(result.succeeded, "missing-add fixture command: \(result.standardErrorString)")
            return result
        }
        let container = root.appendingPathComponent("missing-add-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        let count = Int(ProcessInfo.processInfo.environment["SVNDOCK_MISSING_ADDITION_COUNT"] ?? "600") ?? 600
        guard (1...100_000).contains(count) else { throw SmokeFailure("invalid missing addition test count") }
        var selectedPaths = [container.path]
        for index in 0..<count {
            let group = container.appendingPathComponent("group-\(index / 100)", isDirectory: true)
            if index % 100 == 0 {
                try FileManager.default.createDirectory(at: group, withIntermediateDirectories: false)
                selectedPaths.append(group.path)
            }
            let file = group.appendingPathComponent("file-\(index).txt")
            try Data("temporary addition".utf8).write(to: file)
            selectedPaths.append(file.path)
        }
        _ = try await run(.add(paths: [container.path], parents: false, force: false, depth: .infinity))
        try FileManager.default.removeItem(at: container)
        let targets = try undo.targets(for: selectedPaths, in: workingCopy)
        try check(targets == [container.lastPathComponent], "missing subtree collapses to one root")

        // A missing versioned file must block the complete mixed selection.
        let versioned = root.appendingPathComponent("versioned-\(UUID().uuidString).txt")
        try Data("committed file".utf8).write(to: versioned)
        _ = try await run(.add(paths: [versioned.path], parents: false, force: false, depth: nil))
        _ = try await run(.commit(paths: [versioned.path], message: "missing-add guard fixture", keepLocks: false))
        try FileManager.default.removeItem(at: versioned)
        do {
            try await undo.run(targets: [container.path, versioned.path], in: workingCopy, missingOnly: true)
            throw SmokeFailure("missing versioned file must block cleanup")
        } catch SVNAdditionUndoError.notScheduledAddition {
            // All validation must finish before any revert is performed.
        }
        let preservedInfo = try await run(.infoTargets(paths: [container.path]))
        let preserved = try SVNXMLParser.parseInfo(preservedInfo.standardOutput)
        try check(preserved.schedule == "add", "rejected cleanup preserves pending addition")
        try check(!FileManager.default.fileExists(atPath: versioned.path), "cleanup does not restore missing versioned file")

        let beforeLog = try await run(.log(paths: [], limit: 1))
        let beforeRevision = try SVNXMLParser.parseLog(beforeLog.standardOutput).first?.revision
        try await undo.run(targets: selectedPaths, in: workingCopy, missingOnly: true)
        let afterStatus = try await run(.status(SVNStatusOptions()))
        let entries = try SVNXMLParser.parseStatus(afterStatus.standardOutput, workingCopyURL: root)
        try check(!entries.contains { $0.fileURL(relativeTo: workingCopy).path.hasPrefix(container.path) }, "all missing addition records removed")
        try check(!FileManager.default.fileExists(atPath: container.path), "cleanup does not recreate deleted directory")
        let afterLog = try await run(.log(paths: [], limit: 1))
        let afterRevision = try SVNXMLParser.parseLog(afterLog.standardOutput).first?.revision
        try check(beforeRevision == afterRevision, "missing addition cleanup creates no repository revision")
        _ = try await run(.revert(paths: [versioned.path], depth: .empty))

        // A file restored after opening the confirmation must be left intact.
        let restored = root.appendingPathComponent("restored-add.txt")
        try Data("keep me".utf8).write(to: restored)
        _ = try await run(.add(paths: [restored.path], parents: false, force: false, depth: nil))
        do {
            try await undo.run(targets: [restored.path], in: workingCopy, missingOnly: true)
            throw SmokeFailure("present file must block missing cleanup")
        } catch SVNAdditionUndoError.notMissing {
            // Expected.
        }
        try await undo.run(targets: [restored.path], in: workingCopy, missingOnly: false)
        let retained = try Data(contentsOf: restored)
        try check(retained == Data("keep me".utf8), "ordinary cancel-add preserves file contents")
        print("Missing addition cleanup passed: \(count) files; versioned/restored guards and unchanged repository revision")
    }

    /// Exercises `svn resolve --accept working` against a disposable working
    /// copy in which the caller has already produced a real conflict.
    private static func realSVNResolveCheck(at root: URL) async throws {
        let executable = try SVNExecutableLocator().locate()
        let builder = try SVNCommandBuilder(executableURL: executable)
        let runner = ProcessRunner()
        let workingCopy = WorkingCopy(localPath: root)

        let beforeResult = try await runner.run(
            builder.makeInvocation(
                for: .status(SVNStatusOptions()),
                in: workingCopy
            )
        )
        try check(beforeResult.succeeded, "real resolve preflight status")
        let before = try SVNXMLParser.parseStatus(
            beforeResult.standardOutput,
            workingCopyURL: root
        )
        guard let conflict = before.first(where: {
            $0.status == .conflicted || $0.propertyStatus == .conflicted || $0.isTreeConflicted
        }) else {
            throw SmokeFailure("real resolve requires a conflicted working copy")
        }

        let resolveResult = try await runner.run(
            builder.makeInvocation(
                for: .resolve(paths: [conflict.path], accept: .working),
                in: workingCopy
            )
        )
        try check(resolveResult.succeeded, "real svn resolve working")

        let afterResult = try await runner.run(
            builder.makeInvocation(
                for: .status(SVNStatusOptions()),
                in: workingCopy
            )
        )
        let after = try SVNXMLParser.parseStatus(
            afterResult.standardOutput,
            workingCopyURL: root
        )
        try check(
            !after.contains(where: {
                $0.path == conflict.path
                    && ($0.status == .conflicted
                        || $0.propertyStatus == .conflicted
                        || $0.isTreeConflicted)
            }),
            "real svn resolve clears conflict state"
        )
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw SmokeFailure(label) }
    }
}

private struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private actor SmokeConcurrencyProbe {
    private var active = 0
    private(set) var maximum = 0

    func perform() async {
        active += 1
        maximum = max(maximum, active)
        try? await Task.sleep(nanoseconds: 25_000_000)
        active -= 1
    }
}
#endif
