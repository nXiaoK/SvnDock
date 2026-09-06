import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum IgnoredItemsRegressionChecks {
    @discardableResult
    static func run() async throws -> Bool {
        guard let executable = SVNExecutableLocator.defaultCandidatePaths
            .map({ URL(fileURLWithPath: $0) }).first(where: {
                FileManager.default.isExecutableFile(atPath: $0.path)
                    && FileManager.default.isExecutableFile(atPath: $0.deletingLastPathComponent()
                        .appendingPathComponent("svnadmin").path)
            }) else {
            print("SKIP ignored items integration: SVN and svnadmin are unavailable")
            return false
        }
        let fixture = try IgnoredItemsFixture(executable: executable)
        defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        try await fixture.create()
        try await exactRulePreservesOtherPropertiesAndContent(fixture)
        try await sharedPatternsExposeTheirWholeScope(fixture)
        try await ignoredDirectoriesRemainOpaque(fixture)
        try await unsupportedSourcesAndPartialSuccess(fixture)
        try await stalePlansCannotOverwriteNewState(fixture)
        try await workingCopyBoundaries(fixture)
        print("Ignored items integration passed: exact/glob rules, sibling scope, opaque directories, source limits, stale plans and WC boundaries")
        return true
    }

    private static func exactRulePreservesOtherPropertiesAndContent(_ fixture: IgnoredItemsFixture) async throws {
        let path = "exact/selected@文本.cache"
        try fixture.write("keep selected contents\n", to: path)
        try fixture.write("keep sibling contents\n", to: "exact/keep.cache")
        let original = "selected@文本.cache\nkeep.cache\n\nREADME.keep\n"
        try await fixture.setIgnore(original, on: "exact")
        _ = try await fixture.svn(["propset", "fixture:other", "untouched", "exact"])
        _ = try await fixture.svn(["commit", "-m", "Seed direct ignore rules", "--", "exact"])
        let localBefore = try await fixture.service.status(for: fixture.copy)
        try check(!localBefore.entries.contains { $0.relativePath == path },
                  "ordinary status does not expose ignored files")
        let entry = try await fixture.ignored(path)
        let mutationCount = await fixture.runner.propertyMutationCount
        let plan = try await fixture.service.prepareIgnoreRemoval(for: entry, in: fixture.copy)
        try check(plan.patterns == ["selected@文本.cache"] && !plan.hasWildcardPatterns,
                  "the preview identifies only the matching exact-name rule")
        try check(plan.originalPropertyValue == original
                    && plan.updatedPropertyValue == "keep.cache\n\nREADME.keep\n",
                  "the preview preserves unmatched lines and their trailing newline")
        try check(plan.affectedSiblingPaths == [path], "exact-name preview affects only the selected item")
        try check(await fixture.runner.propertyMutationCount == mutationCount,
                  "preparing a confirmation is read-only")
        try await fixture.service.removeIgnoreRule(plan, in: fixture.copy)
        try check(try await fixture.property("svn:ignore", on: "exact") == plan.updatedPropertyValue,
                  "only the confirmed direct ignore rule is removed")
        try check(try await fixture.property("fixture:other", on: "exact") == "untouched",
                  "removal preserves unrelated directory properties")
        let status = try await fixture.status()
        try check(status.contains { $0.path == path && $0.status == .unversioned }
                    && status.contains { $0.path == "exact/keep.cache" && $0.status == .ignored },
                  "selected content becomes unversioned while sibling rules still apply")
        try check(status.contains { $0.path == "exact" && $0.propertyStatus == .modified },
                  "the parent property remains a normal local change for a later commit")
        try check(try fixture.read(path) == "keep selected contents\n"
                    && fixture.read("exact/keep.cache") == "keep sibling contents\n",
                  "rule removal leaves selected and sibling file content intact")
        let localAfter = try await fixture.service.status(for: fixture.copy)
        try check(localAfter.entries.contains { $0.relativePath == path && $0.status == .unversioned },
                  "production local status restores the actual SVN state after removing a rule")
    }

    private static func sharedPatternsExposeTheirWholeScope(_ fixture: IgnoredItemsFixture) async throws {
        for path in ["extensions/selected.log", "extensions/sibling.log", "extensions/keep.cache",
                     "extensions/archive.log/nested/sentinel.txt"] {
            try fixture.write("preserved\n", to: path)
        }
        try await fixture.setIgnore("*.log\nkeep.cache\n", on: "extensions")
        let plan = try await fixture.service.prepareIgnoreRemoval(
            for: fixture.ignored("extensions/selected.log"), in: fixture.copy)
        try check(plan.patterns == ["*.log"] && plan.hasWildcardPatterns,
                  "extension rules are identified as sharing a wildcard scope")
        try check(Set(plan.affectedSiblingPaths) == Set([
            "extensions/selected.log", "extensions/sibling.log", "extensions/archive.log"
        ]), "extension preview includes matching sibling files and directories without their children")
        try await fixture.service.removeIgnoreRule(plan, in: fixture.copy)
        let status = try await fixture.status()
        for path in plan.affectedSiblingPaths {
            try check(status.contains { $0.path == path && $0.status == .unversioned },
                      "every item sharing the removed extension rule is exposed: \(path)")
        }
        try check(status.contains { $0.path == "extensions/keep.cache" && $0.status == .ignored },
                  "extension removal retains unrelated ignore rules")
        try check(try fixture.read("extensions/archive.log/nested/sentinel.txt") == "preserved\n",
                  "removing a rule for a matching directory preserves its descendants")

        for path in ["globs/item7.tmp", "globs/item77.tmp", "globs/keep.cache"] {
            try fixture.write("preserved\n", to: path)
        }
        try await fixture.setIgnore("item?.tmp\nitem[0-9].tmp\n*.tmp\nkeep.cache\n", on: "globs")
        let globPlan = try await fixture.service.prepareIgnoreRemoval(
            for: fixture.ignored("globs/item7.tmp"), in: fixture.copy)
        try check(globPlan.patterns == ["item?.tmp", "item[0-9].tmp", "*.tmp"],
                  "all matching direct SVN glob rules appear in the preview")
        try check(Set(globPlan.affectedSiblingPaths) == Set(["globs/item7.tmp", "globs/item77.tmp"]),
                  "overlapping glob rules report the union of affected siblings once")
        try await fixture.service.removeIgnoreRule(globPlan, in: fixture.copy)
        try check(try await fixture.property("svn:ignore", on: "globs") == "keep.cache\n",
                  "removing overlapping rules retains only unmatched property lines")
        try check(!(try await fixture.service.ignoredEntries(for: fixture.copy))
            .contains { $0.relativePath == "globs/item7.tmp" || $0.relativePath == "globs/item77.tmp" },
                  "preview glob matching agrees with the real SVN client")
    }

    private static func ignoredDirectoriesRemainOpaque(_ fixture: IgnoredItemsFixture) async throws {
        try fixture.write("do not traverse or delete\n", to: "opaque/cache/nested/sentinel.txt")
        try await fixture.setIgnore("cache\n", on: "opaque")
        let entries = try await fixture.service.ignoredEntries(for: fixture.copy)
        guard let entry = entries.first(where: { $0.relativePath == "opaque/cache" }) else {
            throw IgnoredItemsFailure(message: "ignored directory should appear as one row")
        }
        try check(entry.nodeKind == .directory
                    && !entries.contains { $0.relativePath.hasPrefix("opaque/cache/") },
                  "ignored directories are opaque rows rather than recursive file listings")
        let plan = try await fixture.service.prepareIgnoreRemoval(for: entry, in: fixture.copy)
        try check(plan.affectedSiblingPaths == ["opaque/cache"],
                  "directory removal preview does not enumerate descendants")
        try await fixture.service.removeIgnoreRule(plan, in: fixture.copy)
        try check(try fixture.read("opaque/cache/nested/sentinel.txt") == "do not traverse or delete\n",
                  "unignoring an entire directory never deletes its content")
        // SVN canonicalizes an empty svn:ignore value to a single newline.
        let remainingValue = try await fixture.property("svn:ignore", on: "opaque")
        try check(remainingValue?.trimmingCharacters(in: .newlines).isEmpty == true,
                  "the last direct rule can be removed without a failing property deletion")
        let status = try await fixture.status()
        try check(status.contains { $0.path == "opaque/cache" && $0.status == .unversioned }
                    && !status.contains { $0.path.hasPrefix("opaque/cache/") },
                  "the restored directory keeps SVN's unversioned-directory status semantics")
    }

    private static func unsupportedSourcesAndPartialSuccess(_ fixture: IgnoredItemsFixture) async throws {
        _ = try await fixture.svn(["propset", "svn:global-ignores", "*.inherited\n*.overlap\n", "."])
        try fixture.write("inherited\n", to: "sources/selected.inherited")
        try fixture.write("client\n", to: "sources/selected.clientonly")
        for path in ["sources/selected.inherited", "sources/selected.clientonly"] {
            let count = await fixture.runner.propertyMutationCount
            do {
                _ = try await fixture.service.prepareIgnoreRemoval(for: fixture.ignored(path), in: fixture.copy)
                throw IgnoredItemsFailure(message: "non-direct ignore sources cannot produce a removable plan")
            } catch SvnDockIgnoreRemovalError.unsupportedSource { }
            try check(await fixture.runner.propertyMutationCount == count,
                      "unsupported global/client rules cannot mutate a directory property")
        }
        for (directory, name) in [("mixed-inherited", "selected.overlap"), ("mixed-client", "selected.shared")] {
            let path = "\(directory)/\(name)"
            try fixture.write("still present\n", to: path)
            try await fixture.setIgnore(name + "\nkeep.cache\n", on: directory)
            let plan = try await fixture.service.prepareIgnoreRemoval(for: fixture.ignored(path), in: fixture.copy)
            let count = await fixture.runner.propertyMutationCount
            do {
                try await fixture.service.removeIgnoreRule(plan, in: fixture.copy)
                throw IgnoredItemsFailure(message: "remaining global/client rules must not be reported as unignored success")
            } catch SvnDockIgnoreRemovalError.stillIgnored { }
            try check(await fixture.runner.propertyMutationCount == count + 1,
                      "remaining ignore sources never cause an automatic repeat mutation")
            try check(try await fixture.property("svn:ignore", on: directory) == "keep.cache\n",
                      "partial-success feedback corresponds to the direct rule having actually been removed")
            try check(try await fixture.property("svn:global-ignores", on: ".") == "*.inherited\n*.overlap\n",
                      "removal leaves inherited rules untouched")
            try check(try fixture.read(path) == "still present\n", "partial success preserves ignored content")
        }
    }

    private static func stalePlansCannotOverwriteNewState(_ fixture: IgnoredItemsFixture) async throws {
        try fixture.write("preserved\n", to: "stale/selected.cache")
        try await fixture.setIgnore("selected.cache\nkeep.cache\n", on: "stale")
        let plan = try await fixture.service.prepareIgnoreRemoval(
            for: fixture.ignored("stale/selected.cache"), in: fixture.copy)
        let newer = "selected.cache\nkeep.cache\nnewer-rule\n"
        try await fixture.setIgnore(newer, on: "stale")
        let count = await fixture.runner.propertyMutationCount
        do {
            try await fixture.service.removeIgnoreRule(plan, in: fixture.copy)
            throw IgnoredItemsFailure(message: "a changed property must invalidate an earlier confirmation")
        } catch SvnDockIgnoreRemovalError.stalePlan { }
        let afterStaleCount = await fixture.runner.propertyMutationCount
        let afterStaleProperty = try await fixture.property("svn:ignore", on: "stale")
        try check(afterStaleCount == count && afterStaleProperty == newer,
                  "stale confirmation cannot overwrite a newly added rule")

        let fresh = try await fixture.service.prepareIgnoreRemoval(
            for: fixture.ignored("stale/selected.cache"), in: fixture.copy)
        _ = try await fixture.svn(["add", "--no-ignore", "--", "stale/selected.cache"])
        let afterAddCount = await fixture.runner.propertyMutationCount
        let error = try await rejected {
            try await fixture.service.removeIgnoreRule(fresh, in: fixture.copy)
        }
        try check(error is SvnDockServiceError || error is SvnDockIgnoreRemovalError,
                  "a target that became versioned receives a meaningful stale-target error")
        let afterRejectionCount = await fixture.runner.propertyMutationCount
        let afterRejectionProperty = try await fixture.property("svn:ignore", on: "stale")
        try check(afterRejectionCount == afterAddCount && afterRejectionProperty == newer,
                  "a changed selected status also rejects the mutation")
    }

    private static func workingCopyBoundaries(_ fixture: IgnoredItemsFixture) async throws {
        try fixture.write("preserved\n", to: "boundaries/selected.cache")
        try await fixture.setIgnore("selected.cache\n", on: "boundaries")
        let entry = try await fixture.ignored("boundaries/selected.cache")
        let plan = try await fixture.service.prepareIgnoreRemoval(for: entry, in: fixture.copy)
        let foreignCopy = SvnDockWorkingCopy(name: "different identity", rootURL: fixture.copy.rootURL)
        let before = await fixture.runner.invocationCount
        _ = try await rejected {
            _ = try await fixture.service.prepareIgnoreRemoval(for: entry, in: foreignCopy)
        }
        _ = try await rejected {
            try await fixture.service.removeIgnoreRule(plan, in: foreignCopy)
        }
        let wrongRootPlan = SvnDockIgnoreRemovalPlan(workingCopyID: plan.workingCopyID,
            workingCopyRootURL: fixture.temporary.appendingPathComponent("different-root"),
            targetRelativePath: plan.targetRelativePath, parentRelativePath: plan.parentRelativePath,
            patterns: plan.patterns, originalPropertyValue: plan.originalPropertyValue,
            updatedPropertyValue: plan.updatedPropertyValue, affectedSiblingPaths: plan.affectedSiblingPaths)
        _ = try await rejected {
            try await fixture.service.removeIgnoreRule(wrongRootPlan, in: fixture.copy)
        }
        try check(await fixture.runner.invocationCount == before,
                  "working-copy identity or root mismatch is rejected before invoking SVN")

        let outside = fixture.temporary.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("outside must stay untouched\n".utf8).write(to: outside.appendingPathComponent("selected.cache"))
        try FileManager.default.createSymbolicLink(
            at: fixture.copy.rootURL.appendingPathComponent("boundaries/escaped"), withDestinationURL: outside)
        for path in ["../outside/selected.cache", "boundaries/escaped/selected.cache"] {
            let selected = SvnDockStatusEntry(workingCopyID: fixture.copy.id,
                relativePath: path, nodeKind: .file, status: .ignored)
            let count = await fixture.runner.invocationCount
            _ = try await rejected {
                _ = try await fixture.service.prepareIgnoreRemoval(for: selected, in: fixture.copy)
            }
            try check(await fixture.runner.invocationCount == count,
                      "escaped paths are rejected before reading or mutating external targets")
        }

        let nested = fixture.copy.rootURL.appendingPathComponent("boundaries/nested", isDirectory: true)
        _ = try await fixture.svn(["checkout", fixture.repository.absoluteString, nested.path])
        _ = try await fixture.svn(["propset", "svn:ignore", "selected.cache\n", "."], in: nested)
        try Data("nested copy content\n".utf8).write(to: nested.appendingPathComponent("selected.cache"))
        let nestedEntry = SvnDockStatusEntry(workingCopyID: fixture.copy.id,
            relativePath: "boundaries/nested/selected.cache", nodeKind: .file, status: .ignored)
        let count = await fixture.runner.propertyMutationCount
        _ = try await rejected {
            _ = try await fixture.service.prepareIgnoreRemoval(for: nestedEntry, in: fixture.copy)
        }
        try check(await fixture.runner.propertyMutationCount == count,
                  "a nested checkout cannot be edited through its containing working copy")
    }

    private static func rejected(_ operation: () async throws -> Void) async throws -> any Error {
        do { try await operation() } catch { return error }
        throw IgnoredItemsFailure(message: "expected operation to reject an invalid target")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw IgnoredItemsFailure(message: message) }
    }
}

private struct IgnoredItemsFailure: Error { let message: String }

private struct IgnoredItemsFixture: Sendable {
    let temporary: URL
    let repository: URL
    let copy: SvnDockWorkingCopy
    let executable: URL
    let runner: IgnoredItemsIsolatedRunner
    let sharedStore: FinderSharedStore
    let service: CoreSvnDockService

    init(executable: URL) throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("svndock-ignored-items-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        self.temporary = temporary
        self.executable = executable
        repository = temporary.appendingPathComponent("repository", isDirectory: true)
        copy = SvnDockWorkingCopy(name: "ignored fixture", rootURL: temporary.appendingPathComponent("wc", isDirectory: true))
        let configuration = temporary.appendingPathComponent("svn-config", isDirectory: true)
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: false)
        try Data("[miscellany]\nglobal-ignores = *.clientonly *.shared\n".utf8)
            .write(to: configuration.appendingPathComponent("config"))
        runner = IgnoredItemsIsolatedRunner(configuration: configuration)
        sharedStore = try FinderSharedStore(directoryURL: temporary.appendingPathComponent("app-state"))
        service = try CoreSvnDockService(
            sharedStore: sharedStore,
            executableLocator: SVNExecutableLocator(candidatePaths: [executable.path],
                environmentOverrideKey: "SVNDOCK_IGNORED_TEST_UNUSED"),
            processRunner: runner
        )
    }

    func create() async throws {
        let result = try await ProcessRunner().run(ProcessInvocation(
            executableURL: executable.deletingLastPathComponent().appendingPathComponent("svnadmin"),
            arguments: ["create", repository.path]
        ))
        guard result.succeeded else { throw IgnoredItemsFailure(message: "temporary SVN repository creation failed") }
        _ = try await svn(["checkout", repository.absoluteString, copy.rootURL.path], in: temporary)
        _ = try await sharedStore.register(WorkingCopy(id: copy.id, name: copy.name, localPath: copy.rootURL))
        let directories = ["exact", "extensions", "globs", "opaque", "sources", "mixed-inherited", "mixed-client", "stale", "boundaries"]
        for directory in directories {
            try FileManager.default.createDirectory(at: copy.rootURL.appendingPathComponent(directory), withIntermediateDirectories: false)
        }
        _ = try await svn(["add", "--"] + directories)
        _ = try await svn(["commit", "-m", "Seed ignored items fixture", "--", "."])
    }

    func write(_ value: String, to path: String) throws {
        let target = copy.rootURL.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: target)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: copy.rootURL.appendingPathComponent(path), encoding: .utf8)
    }

    func svn(_ arguments: [String], in directory: URL? = nil) async throws -> ProcessResult {
        let result = try await runner.run(ProcessInvocation(executableURL: executable,
            arguments: arguments, currentDirectoryURL: directory ?? copy.rootURL))
        guard result.succeeded else {
            throw IgnoredItemsFailure(message: "fixture SVN command failed: \(result.standardErrorString)")
        }
        return result
    }

    func setIgnore(_ value: String, on path: String) async throws {
        _ = try await svn(["propset", "svn:ignore", value, "--", path + "@"])
    }

    func property(_ name: String, on path: String) async throws -> String? {
        let result = try await svn(["proplist", "--xml", "--verbose", "--", path + "@"])
        return try SVNXMLParser.parseProperties(result.standardOutput).first?.value(forProperty: name)
    }

    func status() async throws -> [StatusEntry] {
        let result = try await svn(["status", "--xml", "--no-ignore"])
        return try SVNXMLParser.parseStatus(result.standardOutput, workingCopyURL: copy.rootURL)
    }

    func ignored(_ path: String) async throws -> SvnDockStatusEntry {
        guard let entry = try await service.ignoredEntries(for: copy).first(where: { $0.relativePath == path }) else {
            throw IgnoredItemsFailure(message: "missing ignored fixture target: \(path)")
        }
        return entry
    }
}

/// Both fixture setup and production service calls use disposable SVN settings.
/// Preserve argument-file offsets so propset uses the real production path.
private actor IgnoredItemsIsolatedRunner: ProcessRunning {
    let configuration: URL
    private(set) var propertyMutationCount = 0
    private(set) var invocationCount = 0

    init(configuration: URL) { self.configuration = configuration }

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        invocationCount += 1
        if invocation.arguments.first == "propset" || invocation.arguments.first == "propdel" {
            propertyMutationCount += 1
        }
        return try await ProcessRunner().run(ProcessInvocation(
            executableURL: invocation.executableURL,
            arguments: ["--config-dir", configuration.path, "--no-auth-cache", "--non-interactive"] + invocation.arguments,
            currentDirectoryURL: invocation.currentDirectoryURL,
            environment: invocation.environment,
            standardInput: invocation.standardInput,
            argumentFiles: invocation.argumentFiles.map {
                ProcessArgumentFile(argumentIndex: $0.argumentIndex + 4, contents: $0.contents)
            }
        ))
    }
}
