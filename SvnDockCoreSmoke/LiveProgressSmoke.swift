#if SVNDOCK_SMOKE_TESTS
import Foundation
import SvnDockCore

enum LiveProgressSmoke {
    static func run() async throws {
        try parserChecks()
        try await processChecks()
        print("Live process output and SVN progress smoke tests passed")
    }

    private static func parserChecks() throws {
        var parser = SVNProgressParser()
        let sample = "Adding         项目/新文件.txt\r\nSending        src/a.swift\nDeleting       old\n"
        // One-byte delivery deliberately splits every multibyte UTF-8 scalar.
        for byte in sample.utf8 {
            _ = parser.consume(ProcessOutputChunk(stream: .standardOutput, data: Data([byte])))
        }
        try check(parser.snapshot.processedItemCount == 3 && parser.snapshot.currentPath == "old",
                  "commit notifications survive arbitrary chunks and CRLF")
        _ = parser.consume(chunk("Transmitting file "))
        try check(parser.snapshot.phase == .processing, "incomplete stage prefix is not guessed")
        _ = parser.consume(chunk("data ..."))
        try check(parser.snapshot.phase == .transferring, "transfer stage is live before newline")
        _ = parser.consume(chunk("done\nCommitting transaction...\nCommitted revision 9.\n"))
        try check(parser.snapshot.phase == .awaitingServer && parser.snapshot.processedItemCount == 3,
                  "server notification never asserts successful completion")
        _ = parser.consume(ProcessOutputChunk(stream: .standardError, data: Data("Sending        password=secret\n".utf8)))
        try check(parser.snapshot.processedItemCount == 3, "stderr cannot fabricate file progress")

        var update = SVNProgressParser()
        _ = update.consume(chunk("Updating '.':\nA    added\r U   properties\n   C tree\nUU   测试/文件@x\n"))
        try check(update.snapshot.processedItemCount == 4 && update.snapshot.currentPath == "测试/文件@x",
                  "update columns report actual item and conflict notifications")
        _ = update.consume(chunk("U     leading-space\n"))
        try check(update.snapshot.currentPath == " leading-space", "update preserves significant path whitespace")
        _ = update.consume(chunk("Summary of conflicts:\n  Text conflicts: 1\nAt revision 10."))
        _ = update.finish()
        try check(update.snapshot.processedItemCount == 5 && update.snapshot.phase == .awaitingServer,
                  "unterminated final line is parsed without counting summaries")

        var privacy = SVNProgressParser()
        _ = privacy.consume(chunk("Sending        svn+ssh://name:secret@host/file?token=private\n"))
        try check(privacy.snapshot.currentPath?.contains("secret") == false
                    && privacy.snapshot.currentPath?.contains("private") == false
                    && privacy.snapshot.currentPath?.contains("host/file") == true,
                  "paths redact URL credentials and tokens before publication")

        var bounded = SVNProgressParser()
        _ = bounded.consume(chunk("Sending        " + String(repeating: "x", count: 40_000)))
        _ = bounded.finish()
        try check(bounded.snapshot.processedItemCount == 0, "oversized unterminated paths are omitted")
        _ = bounded.consume(chunk("Adding  (bin)  image.png\nReplacing      replacement\n"))
        try check(bounded.snapshot.processedItemCount == 2 && bounded.snapshot.currentPath == "replacement",
                  "parser recovers after oversized lines and recognizes binary adds")
        let notifications = (0..<6_000).map { "Sending        file-\($0)\n" }.joined()
        let cumulative = bounded.consume(chunk(notifications))
        try check(cumulative?.processedItemCount == 6_002 && cumulative?.currentPath == "file-5999",
                  "large chunks yield one cumulative snapshot without losing items")
    }

    private static func processChecks() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("SvnDock-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let captured = Capture()
        let handshake = """
        printf 'Sending        first.txt\n'
        printf 'diagnostic\n' >&2
        attempts=0
        while [ ! -f "$1" ]; do
            attempts=$((attempts + 1))
            if [ "$attempts" -gt 5 ]; then exit 72; fi
            /bin/sleep 1
        done
        printf 'Committed revision 2.\n'
        """
        let result = try await ProcessRunner().run(ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", handshake, "fixture", marker.path]
        ), onOutput: { chunk in
            captured.append(chunk)
            if captured.hasBothStreams {
                try? Data("ack".utf8).write(to: marker)
            }
        })
        try check(result.succeeded, "short writes from both streams arrive while the child is still running")
        try check(captured.output == result.standardOutput && captured.errors == result.standardError,
                  "all callbacks finish before return and preserve complete per-stream bytes")

        let flood = """
        (i=0; while [ "$i" -lt 12000 ]; do printf 'stdout-output\n'; i=$((i + 1)); done) &
        i=0; while [ "$i" -lt 12000 ]; do printf 'stderr-output\n' >&2; i=$((i + 1)); done
        wait
        exit 7
        """
        let floodCapture = Capture()
        let flooded = try await ProcessRunner().run(ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", flood]
        ), onOutput: { floodCapture.append($0) })
        try check(flooded.terminationStatus == 7 && !flooded.succeeded,
                  "streaming retains a failed command's exit status")
        try check(flooded.standardOutput == Data(String(repeating: "stdout-output\n", count: 12_000).utf8)
                    && flooded.standardError == Data(String(repeating: "stderr-output\n", count: 12_000).utf8)
                    && floodCapture.output == flooded.standardOutput && floodCapture.errors == flooded.standardError,
                  "large concurrent streams drain without deadlock or lost bytes")

        let boundedCapture = Capture()
        do {
            _ = try await ProcessRunner().run(ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", flood], outputByteLimit: 1_024
            ), onOutput: { boundedCapture.append($0) })
            throw Failure(message: "expected output bound failure")
        } catch ProcessRunnerError.outputLimitExceeded(1_024) {
            try check(boundedCapture.output.count == 1_024 && boundedCapture.errors.count == 1_024,
                      "output caps also bound callbacks while excess bytes are drained")
        }

        let cancellationCapture = Capture()
        let running = Task {
            try await ProcessRunner().run(ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'started\n'; exec /bin/sleep 30"]
            ), onOutput: { cancellationCapture.append($0) })
        }
        defer { running.cancel() }
        for _ in 0..<200 {
            if !cancellationCapture.output.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(!cancellationCapture.output.isEmpty, "cancellation fixture reports before finishing")
        running.cancel()
        do {
            _ = try await running.value
            throw Failure(message: "expected streamed process cancellation")
        } catch is CancellationError {
            // The overload retains the existing cancellation contract.
        }
    }

    private static func chunk(_ value: String) -> ProcessOutputChunk {
        ProcessOutputChunk(stream: .standardOutput, data: Data(value.utf8))
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    private struct Failure: Error { let message: String }

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()
        var output: Data { lock.withLock { stdout } }
        var errors: Data { lock.withLock { stderr } }
        var hasBothStreams: Bool { lock.withLock { !stdout.isEmpty && !stderr.isEmpty } }

        func append(_ chunk: ProcessOutputChunk) {
            lock.withLock {
                if chunk.stream == .standardOutput { stdout.append(chunk.data) }
                else { stderr.append(chunk.data) }
            }
        }
    }
}
#endif
