import Darwin
import Foundation
#if !SVNDOCK_APP_SMOKE
@testable import SvnDockApp
#endif

enum ReviewInteractionRegressionChecks {
    static func localPreviewBoundaries() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("SvnDockPreview-\(UUID().uuidString)")
        let root = fixture.appendingPathComponent("working-copy")
        let sibling = fixture.appendingPathComponent("working-copy-other")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let text = "新增文件\nsecond line\n"
        let file = root.appendingPathComponent("new.txt")
        try Data(text.utf8).write(to: file)
        try check(LocalFilePreview.read(relativePath: "new.txt", rootURL: root) == .text(text),
                  "unversioned UTF-8 content is readable without scheduling an addition")
        try check(try Data(contentsOf: file) == Data(text.utf8), "preview must preserve original bytes")
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".svn").path),
                  "preview does not create SVN metadata")

        try Data().write(to: root.appendingPathComponent("empty.txt"))
        try check(LocalFilePreview.read(relativePath: "empty.txt", rootURL: root) == .text(""),
                  "empty files remain distinct from unsupported content")
        try Data(repeating: 65, count: 129).write(to: root.appendingPathComponent("large.txt"))
        try check(LocalFilePreview.read(relativePath: "large.txt", rootURL: root, limit: 128) == .tooLarge(limit: 128),
                  "oversized files stop before loading a full document")
        try Data([0, 1, 2, 65]).write(to: root.appendingPathComponent("binary.bin"))
        try check(LocalFilePreview.read(relativePath: "binary.bin", rootURL: root) == .binary,
                  "binary content is not displayed as an empty diff")
        try Data([0xE9, 0x20, 0x61]).write(to: root.appendingPathComponent("legacy.txt"))
        try check(LocalFilePreview.read(relativePath: "legacy.txt", rootURL: root) == .unsupportedEncoding,
                  "unsupported text encoding remains distinct from missing files")

        try Data("outside".utf8).write(to: sibling.appendingPathComponent("private.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"),
                                                   withDestinationURL: sibling.appendingPathComponent("private.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked-folder"),
                                                   withDestinationURL: sibling)
        for path in ["link.txt", "linked-folder/private.txt", "../working-copy-other/private.txt", "/etc/hosts", ".svn/wc.db"] {
            guard case .unavailable = LocalFilePreview.read(relativePath: path, rootURL: root) else {
                throw Failure(message: "preview must refuse symlink escapes and invalid relative paths: \(path)")
            }
        }
        guard case .unavailable = LocalFilePreview.read(relativePath: "deleted.txt", rootURL: root) else {
            throw Failure(message: "missing files report a read failure")
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try check(LocalFilePreview.read(relativePath: "folder", rootURL: root) == .unsupportedType,
                  "directory entries are not read as file content")
        let pipe = root.appendingPathComponent("named-pipe")
        try check(mkfifo(pipe.path, 0o600) == 0, "fixture pipe is created")
        try check(LocalFilePreview.read(relativePath: "named-pipe", rootURL: root) == .unsupportedType,
                  "special files must not block the preview reader")
    }

    static func contextSelectionPreservesScope() throws {
        let copyID = UUID()
        let changed = SvnDockStatusEntry(workingCopyID: copyID, relativePath: "edited.txt", nodeKind: .file, status: .modified)
        let added = SvnDockStatusEntry(workingCopyID: copyID, relativePath: "new-folder", nodeKind: .directory, status: .added)
        let unversioned = SvnDockStatusEntry(workingCopyID: copyID, relativePath: "new.txt", nodeKind: .file, status: .unversioned)
        let clean = SvnDockStatusEntry(workingCopyID: copyID, relativePath: "clean.txt", nodeKind: .file, status: .clean)
        let selected = [changed, added, unversioned]
        let context = StatusActionSelection.context(for: changed, selectedEntries: selected)
        try check(context.entryIDs == Set(selected.map(\.id)), "right-clicking a selected row retains the full selection")
        try check(context.addableEntries.map(\.relativePath) == ["new-folder", "new.txt"],
                  "mixed selections expose only the paths supported by add")
        try check(context.revertibleEntries.map(\.relativePath) == ["edited.txt", "new-folder"],
                  "revert excludes unversioned paths without hiding its smaller scope")
        try check(context.countLabel(context.addableEntries.count) == "2 / 3 项", "partial action counts reveal the denominator")

        let outside = StatusActionSelection.context(for: clean, selectedEntries: selected)
        try check(outside.entryIDs == [clean.id], "right-clicking an unselected row targets that row only")
        try check(outside.addableEntries.isEmpty && outside.revertibleEntries.isEmpty,
                  "a clean row offers no inapplicable mutations")
    }

    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    private struct Failure: Error { let message: String }
}
