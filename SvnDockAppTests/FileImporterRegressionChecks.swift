import Foundation
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum FileImporterRegressionChecks {
    private struct Failure: Error { let message: String }
    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }

    @MainActor
    static func run() async throws {
        let copy = SvnDockWorkingCopy(name: "Existing", rootURL: URL(fileURLWithPath: "/tmp/importer-existing"))
        let service = MockSvnDockService(workingCopies: [copy])
        let store = SvnDockStore(service: service)
        try check(await store.load(), "importer fixture loads")
        store.requestDirectoryImport()
        let first = store.fileImportRequest!
        try check(store.isPresentingFileImporter && first.selectsDirectories && store.isInteractionBlocked,
                  "Add opens the shared importer in directory mode")
        store.requestFileRestoreImporter(for: copy)
        try check(store.fileImportRequest == first, "another purpose cannot replace an open picker")
        store.isPresentingFileImporter = false
        try check(store.isInteractionBlocked, "native dismissal retains the request until completion")
        await store.completeFileImport(.success([]), requestID: first.id)
        try check(store.fileImportRequest == nil && !store.isInteractionBlocked, "cancellation unlocks the main window")

        store.requestFileRestoreImporter(for: copy)
        let history = store.fileImportRequest!
        try check(!history.selectsDirectories && store.isPresentingFileImporter, "history reuses the picker in file mode")
        await store.completeFileImport(.success([]), requestID: first.id)
        try check(store.fileImportRequest == history && store.isPresentingFileImporter,
                  "a late cancellation cannot close a newer picker")
        await store.completeFileImport(.failure(CocoaError(.userCancelled)), requestID: history.id)
        try check(store.fileImportRequest == nil && store.presentedError == nil && !store.isInteractionBlocked,
                  "system cancellation also clears the captured history purpose")

        store.requestDirectoryImport()
        let registration = store.fileImportRequest!
        let urls = ["second", "third"].map { URL(fileURLWithPath: "/tmp/importer-\($0)") }
        store.isPresentingFileImporter = false
        let completion = Task { await store.completeFileImport(.success(urls), requestID: registration.id) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.activeOperation == nil {
            guard ContinuousClock.now < deadline else { throw Failure(message: "registration did not start") }
            try await Task.sleep(for: .milliseconds(1))
        }
        await store.completeFileImport(.success([]), requestID: registration.id)
        try check(store.fileImportRequest?.id == registration.id && store.isInteractionBlocked,
                  "duplicate callbacks cannot release an in-flight registration")
        await completion.value
        try check(urls.allSatisfy { url in store.workingCopies.contains { $0.rootURL == url } },
                  "the directory result registers every selected working copy")
        try check(store.fileImportRequest == nil && !store.isInteractionBlocked,
                  "registration and refresh complete without waiting on their own importer gate")

        store.requestDirectoryImport()
        let failed = store.fileImportRequest!
        await store.completeFileImport(.failure(CocoaError(.fileReadNoPermission)), requestID: failed.id)
        try check(store.fileImportRequest == nil && !store.isPresentingFileImporter && store.presentedError != nil,
                  "picker errors report their cause without retaining a hidden modal")
        store.presentedError = nil
        store.requestDirectoryImport()
        try check(store.isPresentingFileImporter && store.fileImportRequest?.selectsDirectories == true,
                  "Add remains usable after cancellation, history selection and errors")
        await store.completeFileImport(.success([]), requestID: store.fileImportRequest!.id)
        print("File importer checks passed: shared purpose, native dismissal, cancellation, stale callbacks, batch registration and retry")
    }
}
