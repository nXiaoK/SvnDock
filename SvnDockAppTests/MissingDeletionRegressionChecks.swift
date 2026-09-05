import Foundation
import SvnDockCore
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum MissingDeletionRegressionChecks {
    @MainActor
    static func run() async throws {
        try await confirmationKeepsCapturedTargets()
        try await cancellationDoesNotDelete()
        try await invalidRequestsDoNotRetargetSelection()
        try await unselectedContextUsesOnlyClickedEntry()
        try await allMissingUsesOnlyVersionedMissingEntries()
        try await workingCopySwitchDoesNotPublishOldResults()
        try await failureCanBeRetried()
    }

    @MainActor
    static func confirmationKeepsCapturedTargets() async throws {
        let service = MissingDeletionTestService()
        let store = SvnDockStore(service: service)
        await store.load()
        let first = try entry("missing-one.txt", in: store)
        let second = try entry("missing-two.txt", in: store)
        let third = try entry("missing-three.txt", in: store)
        let selection: Set<String> = [first.id, second.id]
        store.selectedEntryIDs = selection

        store.requestMissingDeletion(for: first)
        try check(store.isPresentingMissingDeletionConfirmation, "a valid context selection requests confirmation")
        try check(store.selectedEntryIDs == selection, "the context action preserves multiple selected entries")
        let message = store.missingDeletionConfirmationMessage
        store.selectedEntryIDs = [third.id]
        store.requestMissingDeletion(for: third)
        try check(store.missingDeletionConfirmationMessage == message, "a pending confirmation cannot be replaced")
        store.selectedWorkingCopyID = service.secondary.id

        store.confirmMissingDeletion()
        try check(!store.isPresentingMissingDeletionConfirmation && store.activeOperation?.kind == .deleting,
                  "confirmation synchronously blocks new operations before starting deletion")
        try await waitUntil { await service.requests.count == 1 }
        let request = try unwrap(await service.requests.first)
        try check(request.workingCopyID == service.primary.id
                  && Set(request.relativePaths) == [first.relativePath, second.relativePath],
                  "confirmation uses the captured working copy and selection rather than their latest values")
        store.selectedWorkingCopyID = service.primary.id
        await service.finishDeletion()
        try await waitUntil { @MainActor in
            await service.statusRequests.count == 2 && !store.isBusy
        }
        try check(Set(store.committableEntries.map(\.relativePath)) == [first.relativePath, second.relativePath],
                  "successful deletion refreshes the captured working copy into committable deletions")
    }

    @MainActor
    static func cancellationDoesNotDelete() async throws {
        let service = MissingDeletionTestService()
        let store = SvnDockStore(service: service)
        await store.load()
        store.selectedEntryIDs = [try entry("missing-one.txt", in: store).id]
        store.requestMissingDeletion()
        try check(store.isPresentingMissingDeletionConfirmation, "the fixture requests confirmation")
        store.cancelMissingDeletionConfirmation()
        store.confirmMissingDeletion()
        for _ in 0..<20 { await Task.yield() }
        try check(await service.requests.isEmpty, "cancelling discards the pending deletion")
        try check(!store.isPresentingMissingDeletionConfirmation && !store.isInteractionBlocked,
                  "cancelling restores interaction")
    }

    @MainActor
    static func invalidRequestsDoNotRetargetSelection() async throws {
        let service = MissingDeletionTestService()
        let store = SvnDockStore(service: service)
        await store.load()
        let first = try entry("missing-one.txt", in: store)
        let present = try entry("present.txt", in: store)
        var stale = first
        stale.relativePath = "no-longer-in-status.txt"

        store.selectedEntryIDs = [first.id]
        store.requestMissingDeletion(for: stale)
        try check(!store.isPresentingMissingDeletionConfirmation,
                  "a stale context entry cannot fall back to deleting another selected entry")
        store.requestMissingDeletion(for: present)
        try check(!store.isPresentingMissingDeletionConfirmation, "a nonmissing context status rejects deletion")

        for invalidPath in ["present.txt", "missing-addition.txt", "conflicted-missing.txt", "unknown-missing.txt"] {
            let invalid = try entry(invalidPath, in: store)
            store.selectedEntryIDs = [first.id, invalid.id]
            store.requestMissingDeletion(for: first)
            try check(!store.isPresentingMissingDeletionConfirmation,
                      "a mixed context selection must not silently delete only its eligible entries")
            store.requestMissingDeletion()
            try check(!store.isPresentingMissingDeletionConfirmation, "a mixed keyboard selection rejects deletion")
        }
        store.selectedEntryIDs = [first.id, stale.id]
        store.requestMissingDeletion(for: first)
        try check(!store.isPresentingMissingDeletionConfirmation, "an obsolete selected ID rejects the whole request")
        store.requestMissingDeletion()
        try check(!store.isPresentingMissingDeletionConfirmation, "an obsolete selected ID is not silently dropped")

        // Sidebar selection changes before its asynchronous status reload. The
        // previous snapshot must never supply deletion targets for the new WC.
        store.selectedWorkingCopyID = service.secondary.id
        store.selectedEntryIDs = [first.id]
        store.requestMissingDeletion(for: first)
        try check(!store.isPresentingMissingDeletionConfirmation, "a context entry from another WC is rejected")
        store.requestMissingDeletion()
        try check(!store.isPresentingMissingDeletionConfirmation, "old selection cannot target the new WC")
        store.requestMissingDeletion(allMissing: true)
        try check(!store.isPresentingMissingDeletionConfirmation, "the old snapshot cannot target all paths in the new WC")
        store.confirmMissingDeletion()
        for _ in 0..<20 { await Task.yield() }
        try check(await service.requests.isEmpty, "all invalid requests leave the service untouched")
    }

    @MainActor
    static func unselectedContextUsesOnlyClickedEntry() async throws {
        let service = MissingDeletionTestService()
        let store = SvnDockStore(service: service)
        await store.load()
        store.selectedEntryIDs = [try entry("missing-one.txt", in: store).id]
        let clicked = try entry("missing-two.txt", in: store)
        store.requestMissingDeletion(for: clicked)
        store.confirmMissingDeletion()
        try await waitUntil { await service.requests.count == 1 }
        try check(await service.requests.first?.relativePaths == [clicked.relativePath],
                  "right-clicking outside the selection deletes only the clicked entry")
        await service.finishDeletion()
        try await waitUntil { @MainActor in
            await service.statusRequests.count == 2 && !store.isBusy
        }
    }

    @MainActor
    static func allMissingUsesOnlyVersionedMissingEntries() async throws {
        let service = MissingDeletionTestService()
        let store = SvnDockStore(service: service)
        await store.load()
        store.selectedEntryIDs = [try entry("present.txt", in: store).id]
        store.requestMissingDeletion(allMissing: true)
        store.confirmMissingDeletion()
        try await waitUntil { await service.requests.count == 1 }
        let paths = try unwrap(await service.requests.first).relativePaths
        try check(Set(paths) == ["missing-one.txt", "missing-two.txt", "missing-three.txt"],
                  "the banner excludes missing additions, conflicts, unknown schedules, and nonmissing paths")
        await service.finishDeletion()
        try await waitUntil { @MainActor in
            await service.statusRequests.count == 2 && !store.isBusy
        }
    }

    @MainActor
    static func workingCopySwitchDoesNotPublishOldResults() async throws {
        let service = MissingDeletionTestService()
        let store = SvnDockStore(service: service)
        await store.load()
        let first = try entry("missing-one.txt", in: store)
        store.selectedEntryIDs = [first.id]
        store.requestMissingDeletion()
        store.confirmMissingDeletion()
        try await waitUntil { await service.requests.count == 1 }

        store.selectedWorkingCopyID = service.secondary.id
        let nextSelection: Set<String> = ["\(service.secondary.id.uuidString)::other.txt"]
        store.selectedEntryIDs = nextSelection
        let snapshotBeforeCompletion = store.entries
        await service.finishDeletion()
        try await waitUntil { @MainActor in !store.isBusy }
        try check(await service.statusRequests == [service.primary.id],
                  "completion does not refresh either WC after selection changed")
        try check(store.selectedWorkingCopyID == service.secondary.id
                  && store.selectedEntryIDs == nextSelection && store.entries == snapshotBeforeCompletion,
                  "completion cannot overwrite the newly selected working copy or its selection")

        await store.selectedWorkingCopyDidChange(to: service.secondary.id)
        try check(store.entries.allSatisfy { $0.workingCopyID == service.secondary.id }
                  && store.entries.map(\.relativePath) == ["other.txt"],
                  "the next working copy still loads its own status normally")
    }

    @MainActor
    static func failureCanBeRetried() async throws {
        let service = MissingDeletionTestService()
        let store = SvnDockStore(service: service)
        await store.load()
        let first = try entry("missing-one.txt", in: store)
        store.selectedEntryIDs = [first.id]
        store.requestMissingDeletion()
        store.confirmMissingDeletion()
        try await waitUntil { await service.requests.count == 1 }
        await service.finishDeletion(failing: true)
        try await waitUntil { @MainActor in !store.isBusy && store.presentedError != nil }
        try check(store.committableEntries.isEmpty, "a failed service operation does not report a scheduled deletion")
        try check(!store.isPresentingMissingDeletionConfirmation, "a failed operation clears its confirmation")

        store.presentedError = nil
        store.selectedEntryIDs = [first.id]
        store.requestMissingDeletion()
        try check(store.isPresentingMissingDeletionConfirmation, "the user can request a retry after dismissing the error")
        store.confirmMissingDeletion()
        try await waitUntil { await service.requests.count == 2 }
        await service.finishDeletion()
        try await waitUntil { @MainActor in !store.isBusy && store.committableEntries.count == 1 }
        try check(store.presentedError == nil && store.committableEntries.first?.relativePath == first.relativePath,
                  "a fresh confirmed retry can succeed")
    }

    @MainActor
    private static func entry(_ path: String, in store: SvnDockStore) throws -> SvnDockStatusEntry {
        try unwrap(store.entries.first { $0.relativePath == path })
    }

    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw MissingDeletionTestFailure(message: "missing deletion fixture is absent") }
        return value
    }

    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw MissingDeletionTestFailure(message: message) }
    }

    @MainActor
    private static func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard clock.now < deadline else {
                throw MissingDeletionTestFailure(message: "timed out waiting for missing deletion")
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private struct MissingDeletionTestFailure: Error { let message: String }

private actor MissingDeletionTestService: SvnDockServicing {
    struct Request: Sendable {
        let workingCopyID: UUID
        let relativePaths: [String]
    }

    nonisolated let primary = SvnDockWorkingCopy(
        name: "A fixture", rootURL: URL(fileURLWithPath: "/tmp/svndock-missing-deletion-fixture-a")
    )
    nonisolated let secondary = SvnDockWorkingCopy(
        name: "B fixture", rootURL: URL(fileURLWithPath: "/tmp/svndock-missing-deletion-fixture-b")
    )
    private(set) var requests: [Request] = []
    private(set) var statusRequests: [UUID] = []
    private var deletionContinuation: CheckedContinuation<Void, Error>?
    private var deletedPaths: Set<String> = []

    func loadRegisteredWorkingCopies() async throws -> [SvnDockWorkingCopy] { [primary, secondary] }

    func status(for workingCopy: SvnDockWorkingCopy) async throws -> SvnDockStatusSnapshot {
        statusRequests.append(workingCopy.id)
        if workingCopy.id == secondary.id {
            return SvnDockStatusSnapshot(entries: [
                .init(workingCopyID: secondary.id, relativePath: "other.txt", nodeKind: .file, status: .modified)
            ])
        }
        var entries = [
            makeEntry("missing-one.txt"), makeEntry("missing-two.txt"), makeEntry("missing-three.txt"),
            makeEntry("missing-addition.txt", schedule: "add"), makeEntry("unknown-missing.txt", schedule: nil),
            makeEntry("conflicted-missing.txt", conflictKinds: [.tree]),
            makeEntry("present.txt", status: .clean)
        ]
        // A nonmissing versioned entry exercises eligibility without adding
        // unrelated committable changes to the success/failure assertions.
        for index in entries.indices where deletedPaths.contains(entries[index].relativePath) {
            entries[index].status = .deleted
        }
        return SvnDockStatusSnapshot(entries: entries)
    }

    func scheduleMissingDeletion(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws {
        requests.append(Request(workingCopyID: workingCopy.id, relativePaths: relativePaths))
        try await withCheckedThrowingContinuation { deletionContinuation = $0 }
        deletedPaths.formUnion(relativePaths)
    }

    func finishDeletion(failing: Bool = false) {
        let continuation = deletionContinuation
        deletionContinuation = nil
        if failing {
            continuation?.resume(throwing: MissingDeletionTestFailure(message: "fixture deletion failed"))
        } else {
            continuation?.resume()
        }
    }

    private func makeEntry(
        _ path: String,
        status: SvnDockStatusKind = .missing,
        schedule: String? = "normal",
        conflictKinds: Set<SvnDockConflictKind> = []
    ) -> SvnDockStatusEntry {
        var entry = SvnDockStatusEntry(
            workingCopyID: primary.id, relativePath: path, nodeKind: .file,
            status: status, conflictKinds: conflictKinds
        )
        entry.workingCopySchedule = schedule
        entry.workingCopyRevision = 12
        return entry
    }

    func registerWorkingCopy(at url: URL) async throws -> SvnDockWorkingCopy { throw unsupported }
    func unregisterWorkingCopy(id: UUID) async throws { throw unsupported }
    func directoryChildren(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> [SvnDockStatusEntry] { throw unsupported }
    func diff(relativePath: String, in workingCopy: SvnDockWorkingCopy) async throws -> String { throw unsupported }
    func history(for workingCopy: SvnDockWorkingCopy, relativePaths: [String], limit: Int) async throws -> [SvnDockLogEntry] { throw unsupported }
    func revisionDetails(revision: Int, in workingCopy: SvnDockWorkingCopy) async throws -> SVNRevisionDetails { throw unsupported }
    func revisionDiff(revision: Int, change: SVNChangedPath, repositoryRoot: URL, in workingCopy: SvnDockWorkingCopy) async throws -> String { throw unsupported }
    func update(workingCopies: [SvnDockWorkingCopy]) async throws { throw unsupported }
    func commit(workingCopy: SvnDockWorkingCopy, relativePaths: [String], message: String) async throws { throw unsupported }
    func add(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func unscheduleAdd(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func cleanupMissingAdditions(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func revert(relativePaths: [String], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func resolve(relativePaths: [String], using resolution: SvnDockConflictResolution, in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func addIgnoreRules(_ rules: [SvnDockIgnoreRule], in workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    func cleanup(workingCopy: SvnDockWorkingCopy) async throws { throw unsupported }
    private var unsupported: MissingDeletionTestFailure { MissingDeletionTestFailure(message: "unexpected service call") }
}
