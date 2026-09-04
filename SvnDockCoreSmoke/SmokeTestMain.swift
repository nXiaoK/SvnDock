#if SVNDOCK_SMOKE_TESTS
import Foundation
import SvnDockCore

@main
struct SvnDockCoreSmokeTestMain {
    static func main() async throws {
        try commandBuilderChecks()
        try parserChecks()
        try locatorCheck()
        try await processRunnerCheck()
        try await schedulerCheck()
        try await sharedStoreCheck()
        if let path = ProcessInfo.processInfo.environment["SVNDOCK_INTEGRATION_WC"],
           !path.isEmpty {
            try await realSVNWorkingCopyCheck(at: URL(fileURLWithPath: path, isDirectory: true))
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
            for: .add(paths: ["-safe-because-after-terminator"], parents: false),
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

        let pegSafe = try builder.makeInvocation(
            for: .add(paths: ["notes/user@example.txt"], parents: false),
            in: workingCopy
        )
        try check(pegSafe.arguments.last == "notes/user@example.txt@", "peg revision escaping")

        let diffLiteral = try builder.makeInvocation(
            for: .diff(paths: ["notes/user@example.txt"]),
            in: workingCopy
        )
        try check(diffLiteral.arguments.last == "notes/user@example.txt", "diff @ literal")

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

        let file = root.appendingPathComponent("integration@example.txt")
        try Data("first version\n".utf8).write(to: file, options: .atomic)

        let addResult = try await runner.run(
            builder.makeInvocation(
                for: .add(paths: [file.path], parents: false),
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
