import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum SVNXMLParserError: Error, LocalizedError, Equatable, Sendable {
    case malformedXML(message: String, line: Int, column: Int)
    case missingRequiredValue(String)
    case unsupportedPropertyEncoding(String)

    public var errorDescription: String? {
        switch self {
        case let .malformedXML(message, line, column):
            return "Malformed SVN XML at \(line):\(column): \(message)"
        case let .missingRequiredValue(value):
            return "SVN XML is missing a required value: \(value)"
        case let .unsupportedPropertyEncoding(encoding):
            return "SVN property XML uses an unsupported encoding: \(encoding)"
        }
    }
}

public enum SVNXMLParser {
    public static func parseStatus(
        _ data: Data,
        workingCopyURL: URL? = nil,
        resolveNodeKinds: Bool = true
    ) throws -> [StatusEntry] {
        let delegate = StatusXMLDelegate(
            workingCopyURL: workingCopyURL,
            resolveNodeKinds: resolveNodeKinds
        )
        try parse(data, delegate: delegate)
        return delegate.entries
    }

    public static func parseInfo(_ data: Data) throws -> SVNInfo {
        let infos = try parseInfos(data)
        guard let info = infos.first else {
            throw SVNXMLParserError.missingRequiredValue("info/entry")
        }
        return info
    }

    public static func parseInfos(_ data: Data) throws -> [SVNInfo] {
        let delegate = InfoXMLDelegate()
        try parse(data, delegate: delegate)
        return delegate.infos
    }

    public static func parseLog(_ data: Data) throws -> [SVNLogEntry] {
        let delegate = LogXMLDelegate()
        try parse(data, delegate: delegate)
        guard !delegate.hasEntryWithoutRevision else {
            throw SVNXMLParserError.missingRequiredValue("log/logentry@revision")
        }
        return delegate.entries
    }

    public static func parseProperties(_ data: Data) throws -> [SVNPropertyListEntry] {
        let delegate = PropertiesXMLDelegate()
        try parse(data, delegate: delegate)
        if let encoding = delegate.unsupportedEncoding {
            throw SVNXMLParserError.unsupportedPropertyEncoding(encoding)
        }
        return delegate.entries
    }

    public static func parseDiffSummary(_ data: Data) throws -> [SVNDiffSummaryEntry] {
        let delegate = DiffSummaryXMLDelegate()
        try parse(data, delegate: delegate)
        return delegate.entries
    }

    private static func parse(_ data: Data, delegate: XMLParserDelegate) throws {
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            let error = parser.parserError
            throw SVNXMLParserError.malformedXML(
                message: error?.localizedDescription ?? "unknown parse error",
                line: parser.lineNumber,
                column: parser.columnNumber
            )
        }
    }
}

private final class PropertiesXMLDelegate: NSObject, XMLParserDelegate {
    private struct PendingEntry {
        let path: String
        var properties: [SVNProperty] = []
    }

    private(set) var entries: [SVNPropertyListEntry] = []
    private(set) var unsupportedEncoding: String?
    private var currentEntry: PendingEntry?
    private var currentPropertyName: String?
    private var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        text = ""
        switch elementName {
        case "target":
            if let path = attributeDict["path"] {
                currentEntry = PendingEntry(path: path)
            }
        case "property":
            currentPropertyName = attributeDict["name"]
            if let encoding = attributeDict["encoding"], encoding.lowercased() != "utf-8" {
                unsupportedEncoding = encoding
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "property":
            if let name = currentPropertyName {
                currentEntry?.properties.append(SVNProperty(name: name, value: text))
            }
            currentPropertyName = nil
        case "target":
            if let pending = currentEntry {
                entries.append(SVNPropertyListEntry(
                    path: pending.path,
                    properties: pending.properties
                ))
            }
            currentEntry = nil
        default:
            break
        }
        text = ""
    }
}

private final class LogXMLDelegate: NSObject, XMLParserDelegate {
    private struct PendingEntry {
        let revision: Int?
        var author: String?
        var date: Date?
        var message = ""
        var changedPaths: [SVNChangedPath] = []
    }

    private(set) var entries: [SVNLogEntry] = []
    private(set) var hasEntryWithoutRevision = false
    private var currentEntry: PendingEntry?
    private var text = ""
    private var pathAttributes: [String: String]?
    private let dates = SVNDateParser()

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        text = ""
        if elementName == "logentry" {
            currentEntry = PendingEntry(revision: attributeDict["revision"].flatMap(Int.init))
        } else if elementName == "path" {
            pathAttributes = attributeDict
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "path":
            if let attributes = pathAttributes {
                currentEntry?.changedPaths.append(SVNChangedPath(
                    path: text,
                    action: SVNChangeAction(rawValue: attributes["action"] ?? "") ?? .unknown,
                    kind: SVNNodeKind(svnValue: attributes["kind"]),
                    copyFromPath: attributes["copyfrom-path"],
                    copyFromRevision: attributes["copyfrom-rev"].flatMap(Int.init)
                ))
            }
            pathAttributes = nil
        case "author":
            currentEntry?.author = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        case "date":
            currentEntry?.date = dates.date(
                from: text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        case "msg":
            currentEntry?.message = text
        case "logentry":
            guard let pending = currentEntry else { break }
            guard let revision = pending.revision else {
                hasEntryWithoutRevision = true
                currentEntry = nil
                break
            }
            entries.append(SVNLogEntry(
                revision: revision,
                author: pending.author,
                date: pending.date,
                message: pending.message,
                changedPaths: pending.changedPaths
            ))
            currentEntry = nil
        default:
            break
        }
        text = ""
    }
}

private final class DiffSummaryXMLDelegate: NSObject, XMLParserDelegate {
    var entries: [SVNDiffSummaryEntry] = []
    private var attributes: [String: String]?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "path" { attributes = attributeDict; text = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if attributes != nil { text += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "path", let attributes else { return }
        let action: SVNChangeAction = switch attributes["item"] {
        case "added": .added
        case "deleted": .deleted
        case "replaced": .replaced
        default: .modified
        }
        entries.append(SVNDiffSummaryEntry(
            url: text, action: action,
            kind: SVNNodeKind(svnValue: attributes["kind"])
        ))
        self.attributes = nil
        text = ""
    }
}

private final class StatusXMLDelegate: NSObject, XMLParserDelegate {
    private struct PendingEntry {
        let path: String
        let changelist: String?
        var status: SVNStatus?
        var propertyStatus: SVNStatus = .none
        var repositoryStatus: SVNStatus?
        var revision: Int?
        var isCopied = false
        var isSwitched = false
        var isTreeConflicted = false
        var commitRevision: Int?
        var commitAuthor: String?
        var commitDate: Date?
    }

    let workingCopyURL: URL?
    let resolveNodeKinds: Bool
    private(set) var entries: [StatusEntry] = []
    private var currentChangelist: String?
    private var currentEntry: PendingEntry?
    private var text = ""
    private let dates = SVNDateParser()

    init(workingCopyURL: URL?, resolveNodeKinds: Bool) {
        self.workingCopyURL = workingCopyURL?.standardizedFileURL
        self.resolveNodeKinds = resolveNodeKinds
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        text = ""

        switch elementName {
        case "changelist":
            currentChangelist = attributeDict["name"]

        case "entry":
            guard let path = attributeDict["path"] else { return }
            currentEntry = PendingEntry(path: path, changelist: currentChangelist)

        case "wc-status":
            guard currentEntry != nil else { return }
            currentEntry?.status = SVNStatus(svnValue: attributeDict["item"] ?? "")
            currentEntry?.propertyStatus = SVNStatus(svnValue: attributeDict["props"] ?? "none")
            currentEntry?.revision = Self.integer(attributeDict["revision"])
            currentEntry?.isCopied = Self.boolean(attributeDict["copied"])
            currentEntry?.isSwitched = Self.boolean(attributeDict["switched"])
            currentEntry?.isTreeConflicted = Self.boolean(attributeDict["tree-conflicted"])

        case "repos-status":
            guard currentEntry != nil else { return }
            currentEntry?.repositoryStatus = SVNStatus(svnValue: attributeDict["item"] ?? "none")

        case "commit":
            guard currentEntry != nil else { return }
            currentEntry?.commitRevision = Self.integer(attributeDict["revision"])

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "author":
            if !value.isEmpty {
                currentEntry?.commitAuthor = value
            }

        case "date":
            currentEntry?.commitDate = dates.date(from: value)

        case "entry":
            if let pending = currentEntry, let status = pending.status {
                let commit: SVNCommitInfo?
                if pending.commitRevision != nil || pending.commitAuthor != nil || pending.commitDate != nil {
                    commit = SVNCommitInfo(
                        revision: pending.commitRevision,
                        author: pending.commitAuthor,
                        date: pending.commitDate
                    )
                } else {
                    commit = nil
                }

                entries.append(StatusEntry(
                    path: pending.path,
                    kind: nodeKind(for: pending.path),
                    status: status,
                    propertyStatus: pending.propertyStatus,
                    repositoryStatus: pending.repositoryStatus,
                    revision: pending.revision,
                    isCopied: pending.isCopied,
                    isSwitched: pending.isSwitched,
                    isTreeConflicted: pending.isTreeConflicted,
                    changelist: pending.changelist,
                    lastCommit: commit
                ))
            }
            currentEntry = nil

        case "changelist":
            currentChangelist = nil

        default:
            break
        }

        text = ""
    }

    private func nodeKind(for path: String) -> SVNNodeKind {
        guard resolveNodeKinds, let workingCopyURL else { return .unknown }

        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path).standardizedFileURL
        } else {
            url = workingCopyURL.appendingPathComponent(path).standardizedFileURL
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .unknown
        }
        return isDirectory.boolValue ? .directory : .file
    }

    private static func integer(_ value: String?) -> Int? {
        value.flatMap(Int.init)
    }

    private static func boolean(_ value: String?) -> Bool {
        switch value?.lowercased() {
        case "true", "yes", "1": return true
        default: return false
        }
    }
}

private final class InfoXMLDelegate: NSObject, XMLParserDelegate {
    private struct PendingInfo {
        let path: String
        let kind: SVNNodeKind
        let revision: Int?
        var url: URL?
        var repositoryRootURL: URL?
        var repositoryUUID: String?
        var workingCopyRootURL: URL?
        var schedule: String?
        var depth: String?
        var commitRevision: Int?
        var commitAuthor: String?
        var commitDate: Date?
    }

    private(set) var infos: [SVNInfo] = []
    private var currentInfo: PendingInfo?
    private var text = ""
    private let dates = SVNDateParser()

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        text = ""

        switch elementName {
        case "entry":
            guard let path = attributeDict["path"] else { return }
            currentInfo = PendingInfo(
                path: path,
                kind: SVNNodeKind(svnValue: attributeDict["kind"]),
                revision: attributeDict["revision"].flatMap(Int.init)
            )

        case "commit":
            currentInfo?.commitRevision = attributeDict["revision"].flatMap(Int.init)

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "url":
            currentInfo?.url = URL(string: value)
        case "root":
            currentInfo?.repositoryRootURL = URL(string: value)
        case "uuid":
            currentInfo?.repositoryUUID = value.nilIfEmpty
        case "wcroot-abspath":
            if !value.isEmpty {
                currentInfo?.workingCopyRootURL = URL(fileURLWithPath: value, isDirectory: true)
            }
        case "schedule":
            currentInfo?.schedule = value.nilIfEmpty
        case "depth":
            currentInfo?.depth = value.nilIfEmpty
        case "author":
            currentInfo?.commitAuthor = value.nilIfEmpty
        case "date":
            currentInfo?.commitDate = dates.date(from: value)
        case "entry":
            if let pending = currentInfo {
                let commit: SVNCommitInfo?
                if pending.commitRevision != nil || pending.commitAuthor != nil || pending.commitDate != nil {
                    commit = SVNCommitInfo(
                        revision: pending.commitRevision,
                        author: pending.commitAuthor,
                        date: pending.commitDate
                    )
                } else {
                    commit = nil
                }

                infos.append(SVNInfo(
                    path: pending.path,
                    kind: pending.kind,
                    revision: pending.revision,
                    url: pending.url,
                    repositoryRootURL: pending.repositoryRootURL,
                    repositoryUUID: pending.repositoryUUID,
                    workingCopyRootURL: pending.workingCopyRootURL,
                    schedule: pending.schedule,
                    depth: pending.depth,
                    lastCommit: commit
                ))
            }
            currentInfo = nil
        default:
            break
        }

        text = ""
    }
}

// Each XML delegate reuses its own formatters. Large status/log responses can
// contain thousands of dates; constructing an ICU formatter per entry is costly.
// Keeping them local also avoids sharing mutable formatters between parses.
private final class SVNDateParser {
    private lazy var fractional: ISO8601DateFormatter = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional
    }()

    private lazy var wholeSeconds: ISO8601DateFormatter = {
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds
    }()

    func date(from string: String) -> Date? {
        guard !string.isEmpty else { return nil }
        if let date = fractional.date(from: string) {
            return date
        }
        return wholeSeconds.date(from: string)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
