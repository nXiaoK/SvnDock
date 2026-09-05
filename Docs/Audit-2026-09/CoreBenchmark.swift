import Foundation
import Darwin
@main enum Benchmark {
    static func main() throws {
        let mode = CommandLine.arguments[1]
        let start: ContinuousClock.Instant
        switch mode {
        case "xml":
            let count = 5000
            let xml = Data(("<log>" + (0..<count).map { index in
                "<logentry revision=\"\(index + 1)\"><date>2026-09-04T02:03:04.125Z</date><msg>entry \(index)</msg></logentry>"
            }.joined() + "</log>").utf8)
            start = ContinuousClock.now
            let entries = try SVNXMLParser.parseLog(xml)
            print("entries=\(entries.count) last=\(entries.last!.date!) elapsed=\(start.duration(to: .now))")
        case "diff":
            let count = 100000
            let text = "@@ -0,0 +1,\(count) @@\r\n" + (1...count).map { "+line \($0) " + String(repeating: "x", count: 80) + "\r\n" }.joined()
            start = ContinuousClock.now
            let parsed = UnifiedDiffParser.parse(text)
            print("rows=\(parsed.hunks[0].rows.count) last=\(parsed.hunks[0].rows.last!.newLineNumber!) elapsed=\(start.duration(to: .now))")
        case "targets":
            let paths = (0..<60000).map { "Sources/Directory/File-\($0)-" + String(repeating: "x", count: 40) + ".txt" }
            let root = URL(fileURLWithPath: "/private/tmp/SvnDock-core-perf/targets-wc", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let workingCopy = WorkingCopy(localPath: root)
            let builder = try SVNCommandBuilder(executableURL: URL(fileURLWithPath: "/usr/bin/svn"))
            start = ContinuousClock.now
            let invocation = try builder.makeInvocation(for: .commit(paths: paths, message: "Benchmark targets", keepLocks: false), in: workingCopy)
            print("bytes=\(invocation.argumentFiles[0].contents.count) elapsed=\(start.duration(to: .now))")
        default: fatalError("Unknown benchmark")
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("peak_rss_bytes=\(usage.ru_maxrss)")
    }
}
