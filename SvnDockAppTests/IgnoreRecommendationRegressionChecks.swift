import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum IgnoreRecommendationRegressionChecks {
    @MainActor
    static func run() async throws {
        let executable = try SVNExecutableLocator().locate()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("svndock-ignore-recommendations-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = directory.appendingPathComponent("repo", isDirectory: true)
        let root = directory.appendingPathComponent("wc", isDirectory: true)
        let runner = RecommendationRunner(config: directory.appendingPathComponent("config"))
        let admin = try await ProcessRunner().run(.init(executableURL: executable.deletingLastPathComponent().appendingPathComponent("svnadmin"), arguments: ["create", repo.path]))
        try check(admin.succeeded, "disposable repository creation succeeds")
        func svn(_ args: [String], cwd: URL? = nil) async throws -> ProcessResult {
            let result = try await runner.run(.init(executableURL: executable, arguments: args, currentDirectoryURL: cwd ?? root))
            try check(result.succeeded, "SVN fixture command failed: \(result.standardErrorString)")
            return result
        }
        _ = try await svn(["checkout", repo.absoluteString, root.path], cwd: directory)
        func write(_ path: String, _ text: String = "fixture content") throws {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        for path in ["tracked/package.json", "tracked/dist/keep.js", "tracked/src/keep.ts",
                     "tracked/.github/workflows/shared.yml", "tracked/.idea/modules.xml", "tracked/outputs/deliverable.txt"] { try write(path) }
        _ = try await svn(["add", "tracked"])
        _ = try await svn(["propset", "svn:ignore", "existing-rule", "tracked"])
        _ = try await svn(["propset", "custom:keep", "preserved", "tracked"])
        _ = try await svn(["commit", "-m", "Seed tracked project", "."])
        let contents = ["web/package.json", "web/package-lock.json", "web/src/App.vue", "web/node_modules/pkg/index.js",
                        "web/dist/output.js", "web/.idea/workspace.xml", "web/.idea/modules.xml",
                        "python/pyproject.toml", "python/.venv/bin/python", "python/__pycache__/x.pyc",
                        "java/pom.xml", "java/target/classes/Main.class", "swift/Package.swift", "swift/.build/debug/tool",
                        "rust/Cargo.toml", "rust/target/debug/tool", "dotnet/App.csproj", "dotnet/obj/cache",
                        "flutter/pubspec.yaml", "flutter/.dart_tool/cache", "plain/dist/important.txt",
                        "docs/backup/important.docx", "tracked/node_modules/pkg/index.js", "tracked/.idea/workspace.xml",
                        "imported/.git/config", "imported/.github/workflows/ci.yml", "imported/.idea/modules.xml",
                        "imported/outputs/result.txt", "imported/backend/pom.xml", "imported/backend/parent/module/pom.xml",
                        "imported/backend/parent/module/src/Main.java", "imported/backend/parent/module/target/classes/Main.class",
                        "imported/backend/inherited-module/target/classes/Inherited.class",
                        "worktree/.git", "worktree/src/keep.swift", "plain/target/important.txt"]
        for path in contents { try write(path) }
        // A first import often already has a scheduled parent after applying
        // other ignore rules, while its nested Maven modules remain unversioned.
        _ = try await svn(["add", "--depth", "empty", "imported"])
        for index in 0..<320 { try write("imported/outputs/run-\(index)/result.txt") }
        // Never infer directory rules from plain files or follow symlinked
        // metadata/output locations, even when their names are recognized.
        for name in [".github", ".idea", "outputs"] { try write("plain-files/" + name) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("linked-metadata"), withIntermediateDirectories: false)
        for name in [".git", ".github", ".idea", "outputs"] {
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked-metadata/" + name), withDestinationURL: root.appendingPathComponent("web"))
        }
        _ = try await svn(["checkout", repo.absoluteString, root.appendingPathComponent("nested").path])
        try write("nested/package.json")
        try write("nested/node_modules/keep.txt")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: root.appendingPathComponent("web"))
        let shared = try FinderSharedStore(directoryURL: directory.appendingPathComponent("shared"))
        let service = try CoreSvnDockService(sharedStore: shared, executableLocator: .init(candidatePaths: [executable.path]), processRunner: runner)
        let copy = try await service.registerWorkingCopy(at: root)
        let before = try await svn(["status", "--xml", "--no-ignore"])
        let mutations = await runner.mutations
        let plan = try await service.prepareIgnoreRecommendations(in: copy)
        try check(await runner.mutations == mutations, "preparing recommendations never schedules directories or writes properties")
        let ids = Set(plan.items.map(\.id))
        try check(Set(["web/node_modules", "web/dist", "web/.idea", "python/.venv", "python/__pycache__",
                       "java/target", "swift/.build", "rust/target", "dotnet/obj", "flutter/.dart_tool", "tracked/node_modules"]).isSubset(of: ids),
                  "project markers enable scoped recommendations for common build systems")
        let importedSelection: Set<String> = ["imported/.git", "imported/.github", "imported/.idea", "imported/outputs",
                                             "imported/backend/parent/module/target", "imported/backend/inherited-module/target", "worktree/.git"]
        try check(importedSelection.isSubset(of: ids), "first imports detect Git, GitHub, IDEA, outputs and nested Maven targets")
        try check(!plan.isPartial && plan.scannedDirectories < 80,
                  "large recommended output directories cannot exhaust the scan budget before nested Maven modules")
        try check(!ids.contains(where: { $0.hasPrefix("imported/.git/") || $0.hasPrefix("imported/.github/")
                    || $0.hasPrefix("imported/.idea/") || $0.hasPrefix("imported/outputs/") }),
                  "whole directory recommendations do not also offer child rules")
        try check(!ids.contains(where: { $0.hasPrefix("nested/") || $0.hasPrefix("linked/") }), "nested WCs and symlinks are never scanned")
        try check(!ids.contains(where: { $0.hasPrefix("linked-metadata/") || $0.hasPrefix("plain-files/") }),
                  "recognized metadata names do not permit symlink traversal or ignore unrelated regular files")
        try check(!ids.contains("tracked/dist") && !ids.contains("plain/dist") && !ids.contains("web/package-lock.json")
                  && !ids.contains("web/src/App.vue") && !ids.contains("tracked/.idea") && !ids.contains("tracked/.github")
                  && !ids.contains("tracked/outputs") && !ids.contains("plain/target"),
                  "versioned metadata and outputs, ambiguous targets, source and lockfiles are preserved")
        try check(ids.contains("tracked/.idea/workspace.xml"), "versioned IDEA configuration still supports personal workspace ignores")
        let statuses = try SVNXMLParser.parseStatus(before.standardOutput, workingCopyURL: root, resolveNodeKinds: false)
        let limited = try SvnDockIgnoreRecommendationScanner.scan(in: copy, statuses: statuses, limits: .init(directories: 1, entries: 100, depth: 1))
        try check(limited.isPartial && limited.scannedDirectories == 1, "bounded scans report incomplete coverage")
        let cancelled = Task { () throws -> SvnDockIgnoreRecommendationPlan in
            withUnsafeCurrentTask { $0?.cancel() }
            return try SvnDockIgnoreRecommendationScanner.scan(in: copy, statuses: statuses)
        }
        do { _ = try await cancelled.value; throw Failure("cancelled scans must stop") } catch is CancellationError { }

        var wrongCopy = copy
        wrongCopy.repositoryUUID = "unexpected-repository"
        let wrongPlan = SvnDockIgnoreRecommendationPlan(workingCopy: wrongCopy, items: plan.items,
            scannedDirectories: plan.scannedDirectories, isPartial: false)
        do {
            try await service.applyIgnoreRecommendations(wrongPlan, selectedIDs: ["web/node_modules"])
            throw Failure("stale repository identity unexpectedly applied")
        } catch SvnDockServiceError.invalidIgnoreTarget { }
        try check(await runner.mutations == mutations, "changed repository identity rejects before any mutation")
        let switchedStatus = try SVNXMLParser.parseStatus(Data("<status><target path=\".\"><entry path=\"web\"><wc-status item=\"unversioned\" props=\"none\" switched=\"true\"/></entry></target></status>".utf8), resolveNodeKinds: false)
        let switchedPlan = try SvnDockIgnoreRecommendationScanner.scan(in: copy, statuses: statuses + switchedStatus)
        try check(!switchedPlan.items.contains { $0.id.hasPrefix("web/") }, "switched boundaries stay opaque even with duplicate status rows")

        // One stale item rejects the entire recommendation selection before
        // writing even a valid sibling rule or adding an unversioned parent.
        _ = try await svn(["add", "--parents", "--depth", "empty", "web/dist"])
        let afterExternalAdd = await runner.mutations
        do {
            try await service.applyIgnoreRecommendations(plan, selectedIDs: ["web/dist", "tracked/node_modules"])
            throw Failure("stale recommendations unexpectedly applied")
        } catch SvnDockServiceError.invalidIgnoreTarget { }
        try check(await runner.mutations == afterExternalAdd, "stale batch rejection performs no writes")

        // Use the production Store confirmation path, with a repeated click.
        let store = SvnDockStore(service: service)
        _ = await store.load()
        store.requestIgnoreRecommendations()
        let currentCopy = try require(store.selectedWorkingCopy)
        let fresh = try await store.prepareIgnoreRecommendations(in: currentCopy)
        let selected = importedSelection.union(["web/node_modules", "tracked/node_modules", "web/.idea", "tracked/.idea/workspace.xml"])
        store.confirmIgnoreRecommendations(fresh, selectedIDs: selected)
        store.confirmIgnoreRecommendations(fresh, selectedIDs: selected)
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while store.isBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try check(!store.isBusy && store.presentedError == nil && store.operationRecords.first?.outcome == .success,
                  "one-click application finishes and refreshes current state")
        let rules = try await svn(["propget", "--strict", "svn:ignore", "tracked"])
        try check(rules.standardOutputString == "existing-rule\nnode_modules\n", "new rules merge with existing ignore names")
        let otherProperty = try await svn(["propget", "custom:keep", "tracked"])
        try check(otherProperty.standardOutputString == "preserved\n", "other SVN properties remain untouched")
        let ignored = try await service.ignoredEntries(for: currentCopy)
        try check(selected.isSubset(of: Set(ignored.map(\.relativePath))), "every selected recommendation becomes ignored")
        let remaining = try await service.prepareIgnoreRecommendations(in: currentCopy)
        try check(Set(remaining.items.map(\.id)).isDisjoint(with: selected), "applied rules are not recommended again")
        try check(remaining.items.contains { $0.id == "python/.venv" }, "unchecked recommendations remain available")
        for path in contents { try check(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) == "fixture content", "ignore never removes or overwrites \(path)") }
        for index in 0..<320 {
            try check(try String(contentsOf: root.appendingPathComponent("imported/outputs/run-\(index)/result.txt"), encoding: .utf8) == "fixture content",
                      "ignoring a large output directory preserves every file")
        }
        let moduleRules = try await svn(["propget", "--strict", "svn:ignore", "imported/backend/parent/module"])
        try check(moduleRules.standardOutputString == "target\n", "nested Maven output rules are written on the exact module parent")
        let unversionedSource = try await svn(["status", "--xml", "imported/backend/parent/module/src"])
        let sourceStatus = try SVNXMLParser.parseStatus(unversionedSource.standardOutput, workingCopyURL: root, resolveNodeKinds: false)
        try check(sourceStatus.count == 1 && sourceStatus.first?.status == .unversioned,
                  "scheduling a nested ignore parent never recursively adds module source")
        let revision = try await svn(["info", "--show-item", "revision", repo.absoluteString])
        try check(revision.standardOutputString == "1\n", "one-click ignore never creates a repository commit")
        print("Ignore recommendation checks passed: tool metadata, opaque outputs, nested Maven imports, bounded scans, WC boundaries, stale batches, repeat clicks, property merge and content preservation")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }
    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure("missing fixture value") }; return value
    }
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

private actor RecommendationRunner: ProcessRunning {
    let config: URL
    var mutations = 0
    init(config: URL) { self.config = config }
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        if ["add", "propset", "commit"].contains(invocation.arguments.first ?? "") { mutations += 1 }
        return try await ProcessRunner().run(.init(executableURL: invocation.executableURL,
            arguments: ["--config-dir", config.path, "--non-interactive", "--no-auth-cache"] + invocation.arguments,
            currentDirectoryURL: invocation.currentDirectoryURL, environment: invocation.environment,
            standardInput: invocation.standardInput,
            argumentFiles: invocation.argumentFiles.map { .init(argumentIndex: $0.argumentIndex + 4, contents: $0.contents) }))
    }
}
