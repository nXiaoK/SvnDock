#if SVNDOCK_SMOKE_TESTS
import Foundation
import Darwin
import SvnDockCore

enum CoreRegressionSmoke {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func run() async throws {
        try checkDiffParsing()
        try checkLocalPathAliases()
        try checkXMLPathWhitespace()
        try await checkXMLDates()
        try await checkProcessIO()
        try await checkCancellationWithBlockedInput()
        try await checkCancellationWithHelpers()
        print("Core regression checks passed: bounded diff scanning, malformed patches, exact XML paths, reusable XML dates, process I/O and cancellation")
    }

    private static func checkDiffParsing() throws {
        let first = "--- first.txt\n+++ first.txt\n@@ -1 +1 @@\n-old\n+new\n"
        for patch in [
            first + "@@ invalid @@\n-hidden\n+change\n",
            first + "@@ -\(Int.max) +1 @@\n-old\n+new\n",
            first + "@@ -\(Int.max - 1),2 +1 @@\n-old\n+new\n",
            first + "--- second.txt\n+++ second.txt\n@@ -1 +1 @@\n-one\n+two\n"
        ] {
            let document = UnifiedDiffParser.parse(patch)
            try check(document.hunks.isEmpty && document.fallbackText == patch,
                      "Invalid or multi-file patches must retain the full original output")
        }
        let unicode = UnifiedDiffParser.parse("\n@@ -1,2 +1,2 @@\r\n-\r\n-旧\r字\r\n+\r\n+新👨‍👩‍👧‍👦\r\n")
        try check(unicode.rows.map(\.oldText) == ["", "旧\r字"], "CRLF scanning must preserve content")
        try check(unicode.rows.map(\.newText) == ["", "新👨‍👩‍👧‍👦"], "Unicode graphemes must survive scanning")
        let count = 20_000
        let large = "@@ -0,0 +1,\(count) @@\r\n" + (1...count).map { "+行 \($0)\r\n" }.joined()
        let document = UnifiedDiffParser.parse(large)
        try check(document.hunks.count == 1 && document.hunks[0].rows.count == count, "Large diff must retain every row")
        try check(document.hunks[0].rows.last?.newText == "行 \(count)", "Large diff final row must remain visible")
    }

    private static func checkLocalPathAliases() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("SvnDock-path-alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("deleted.txt")
        try Data("before deletion".utf8).write(to: file)
        let copy = WorkingCopy(localPath: root)
        let builder = try SVNCommandBuilder(executableURL: URL(fileURLWithPath: "/usr/bin/svn"))
        let before = try builder.makeInvocation(for: .diff(paths: [file.path]), in: copy)
        try FileManager.default.removeItem(at: file)
        let after = try builder.makeInvocation(for: .diff(paths: [file.path]), in: copy)
        try check(before.arguments == after.arguments && after.arguments.last == "deleted.txt",
                  "Deleting a file must not turn its physical-root alias into an outside path")
        let missing = root.appendingPathComponent("missing-directory/child.txt")
        let invocation = try builder.makeInvocation(for: .revert(paths: [missing.path], depth: .empty), in: copy)
        try check(invocation.arguments.last == "missing-directory/child.txt", "Missing descendants must retain relative targets")
        for outside in [root.path + "-sibling/file.txt", root.path + "/../outside.txt"] {
            do {
                _ = try builder.makeInvocation(for: .diff(paths: [outside]), in: copy)
                throw Failure(description: "Physical aliases must not bypass component boundaries")
            } catch SVNCommandBuilderError.pathOutsideWorkingCopy { }
        }
    }

    private static func checkXMLPathWhitespace() throws {
        for path in ["/tmp/working-copy ", "/tmp/working-copy\t", "/tmp/working-copy\n", "/tmp/working-copy & notes  "] {
            let escapedPath = path.replacingOccurrences(of: "&", with: "&amp;")
            let xml = """
            <info><entry path="working-copy " kind="dir" revision="1">
              <url> https://svn.example.test/repo/trunk%20 </url>
              <repository><root> https://svn.example.test/repo </root><uuid> fixture </uuid></repository>
              <wc-info><wcroot-abspath>\(escapedPath)</wcroot-abspath><schedule> normal </schedule><depth> infinity </depth></wc-info>
            </entry></info>
            """
            let info = try SVNXMLParser.parseInfo(Data(xml.utf8))
            try check(info.workingCopyRootURL?.path == path && info.path == "working-copy ",
                      "SVN XML must preserve whitespace in local paths")
            try check(info.url?.absoluteString == "https://svn.example.test/repo/trunk%20"
                      && info.repositoryRootURL?.absoluteString == "https://svn.example.test/repo"
                      && info.repositoryUUID == "fixture" && info.schedule == "normal" && info.depth == "infinity",
                      "Protocol values must still normalize surrounding whitespace")
        }
    }

    private static func checkXMLDates() async throws {
        let values = ["2026-09-04T02:03:04.125Z", "2026-09-04T02:03:04Z", "invalid", ""]
        let xml = Data(("<log>" + (0..<2_000).map { index in
            "<logentry revision=\"\(index + 1)\"><date>\(values[index % values.count])</date><msg/></logentry>"
        }.joined() + "</log>").utf8)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    let entries = try SVNXMLParser.parseLog(xml)
                    try check(entries.count == 2_000, "Concurrent XML parses must retain every entry")
                    for index in stride(from: 0, to: entries.count, by: 4) {
                        guard let fractional = entries[index].date, let whole = entries[index + 1].date else {
                            throw Failure(description: "Both supported SVN date formats must parse")
                        }
                        try check(abs(fractional.timeIntervalSince(whole) - 0.125) < 0.001, "Fractional dates must retain precision")
                        try check(entries[index + 2].date == nil && entries[index + 3].date == nil,
                                  "Invalid and missing dates must not reuse previous values")
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    private static func checkProcessIO() async throws {
        let runner = ProcessRunner()
        let empty = try await runner.run(ProcessInvocation(executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: []))
        try check(empty.succeeded && empty.standardOutput.isEmpty, "Commands without input must receive EOF")
        let input = Data(repeating: 0x61, count: 2_000_000)
        let closedInput = try await runner.run(ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], standardInput: input
        ))
        try check(closedInput.succeeded, "A child closing stdin early must not deliver fatal SIGPIPE to the app")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    let result = try await runner.run(ProcessInvocation(
                        executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [], standardInput: input
                    ))
                    try check(result.succeeded && result.standardOutput == input, "Concurrent full-duplex pipes must drain")
                }
            }
            try await group.waitForAll()
        }
        let output = String(repeating: "x", count: 32_768)
        let both = try await runner.run(ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s' \"$1\"; printf '%s' \"$1\" >&2", "svndock-test", output]
        ))
        try check(both.succeeded && both.standardOutputString == output && both.standardErrorString == output,
                  "Both output pipes must drain beyond pipe capacity")
    }

    private static func checkCancellationWithBlockedInput() async throws {
        let ready = FileManager.default.temporaryDirectory.appendingPathComponent("SvnDock-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ready) }
        let task = Task {
            try await ProcessRunner().run(ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; printf ready > \"$1\"; exec /bin/sleep 6", "svndock-test", ready.path],
                standardInput: Data(repeating: 0x61, count: 2_000_000)
            ))
        }
        defer { task.cancel() }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try check(FileManager.default.fileExists(atPath: ready.path), "Cancellation fixture must start")
        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
            throw Failure(description: "Cancellation must throw CancellationError")
        } catch is CancellationError { }
        try check(Date().timeIntervalSince(start) < 4, "Cancellation must stop children that ignore SIGTERM while stdin is blocked")
    }

    private static func checkCancellationWithHelpers() async throws {
        // These helpers deliberately ignore SIGTERM. Cover both pipe draining
        // and a helper that can outlive the invocation without holding a pipe.
        for mode in ["pipes", "closed-output", "parent-exits", "all-ignore-term"] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("SvnDock-helper-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let ready = directory.appendingPathComponent("ready")
            let marker = directory.appendingPathComponent("after-cancel")
            let parentDone = directory.appendingPathComponent("parent-done")
            let helper = directory.appendingPathComponent("helper.sh")
            try Data(#"""
                trap '' TERM
                printf '%s' "$$" > "$1"
                /bin/sleep "$3"
                printf unexpected > "$2"
                /bin/sleep 3
                """#.utf8).write(to: helper)
            let parentScript = #"""
                if [ "$1" = all-ignore-term ]; then trap '' TERM; fi
                if [ "$1" = closed-output ]; then
                    /bin/sh "$2" "$3" "$4" "$6" >/dev/null 2>&1 &
                else
                    /bin/sh "$2" "$3" "$4" "$6" &
                fi
                if [ "$1" = parent-exits ]; then
                    /bin/sleep 0.2
                    printf done > "$5"
                    exit 0
                fi
                wait
                """#
            // The stubborn leader gets a two-second TERM grace period. Put
            // its helper's write beyond even the allowed cancellation bound.
            let delay = mode == "all-ignore-term" ? 5.0 : 1.0
            let task = Task {
                try await ProcessRunner().run(ProcessInvocation(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", parentScript, "svndock-test", mode, helper.path,
                                ready.path, marker.path, parentDone.path, String(delay)]
                ))
            }
            defer { task.cancel() }
            // The PID comes only from this disposable fixture. Clean it up if
            // an assertion fails on a runner that still has the original bug.
            var helperPID: pid_t?
            var helperGroup: pid_t?
            defer {
                if let helperPID, let helperGroup, helperGroup > 0,
                   Darwin.getpgid(helperPID) == helperGroup {
                    _ = Darwin.kill(helperPID, SIGKILL)
                }
            }
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if let value = try? String(contentsOf: ready, encoding: .utf8),
                   let pid = pid_t(value), pid > 0 {
                    helperPID = pid
                    helperGroup = Darwin.getpgid(pid)
                    break
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try check(helperPID != nil, "Helper cancellation fixture must start: \(mode)")
            if mode == "parent-exits" {
                while !FileManager.default.fileExists(atPath: parentDone.path), Date() < deadline {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                try check(FileManager.default.fileExists(atPath: parentDone.path), "Fixture parent must exit")
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let start = Date()
            task.cancel()
            do {
                _ = try await task.value
                throw Failure(description: "Helper cancellation must throw CancellationError: \(mode)")
            } catch is CancellationError { }
            try check(Date().timeIntervalSince(start) < 3.5, "Helper must not keep cancellation draining: \(mode)")
            // Wait past the scheduled write, including when stdout/stderr were
            // closed and the runner could otherwise return before the helper.
            let remaining = delay + 0.2 - Date().timeIntervalSince(start)
            if remaining > 0 {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            try check(!FileManager.default.fileExists(atPath: marker.path), "Helper must not write after cancellation: \(mode)")
        }
    }
}
#endif
