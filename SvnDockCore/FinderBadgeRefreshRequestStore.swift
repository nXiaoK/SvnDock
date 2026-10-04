import Darwin
import Foundation

public struct FinderBadgeRefreshDirectory: Codable, Hashable, Sendable {
    public let workingCopyID: UUID
    public let workingCopyRoot: String
    public let directoryPath: String
    public let itemPaths: [String]

    public init(workingCopyID: UUID, workingCopyRoot: String, directoryPath: String, itemPaths: [String] = []) {
        self.workingCopyID = workingCopyID
        self.workingCopyRoot = workingCopyRoot
        self.directoryPath = directoryPath
        self.itemPaths = itemPaths
    }

    private enum CodingKeys: String, CodingKey { case workingCopyID, workingCopyRoot, directoryPath, itemPaths }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workingCopyID = try values.decode(UUID.self, forKey: .workingCopyID)
        workingCopyRoot = try values.decode(String.self, forKey: .workingCopyRoot)
        directoryPath = try values.decode(String.self, forKey: .directoryPath)
        itemPaths = try values.decodeIfPresent([String].self, forKey: .itemPaths) ?? []
    }
}

public struct FinderBadgeRefreshRequest: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let updatedAt: Date
    public let directories: [FinderBadgeRefreshDirectory]
    /// Version 1 publishers hold `.publication.lock` while replacing their hint.
    /// Missing values identify legacy writers whose files must not be pruned.
    public let publicationVersion: Int?

    public init(schemaVersion: Int = 1, id: UUID, updatedAt: Date = Date(), directories: [FinderBadgeRefreshDirectory],
                publicationVersion: Int? = nil) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.updatedAt = updatedAt
        self.directories = directories
        self.publicationVersion = publicationVersion
    }
}

/// Ephemeral observation hints, never executable commands. Requests do not
/// authorize access beyond the deepest currently enabled registered root.
public actor FinderBadgeRefreshRequestStore {
    public static let directoryName = "finder-badge-requests"
    public static let maximumDirectoriesPerRequest = 32
    public static let maximumActiveProcesses = 10
    public static let requestLifetime: TimeInterval = 30
    private static let maximumRequestBytes = 64 * 1_024
    private let directoryURL: URL
    private var cleanupOffset = 0

    public init(baseDirectoryURL: URL) throws {
        guard baseDirectoryURL.isFileURL, baseDirectoryURL.path.hasPrefix("/"),
              baseDirectoryURL.standardizedFileURL.path != "/" else {
            throw FinderSharedStoreError.directoryIsNotAbsoluteFileURL
        }
        directoryURL = baseDirectoryURL.standardizedFileURL.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    public func activeDirectories(registeredRoots: [RegisteredRoot], now: Date = Date()) throws -> [FinderBadgeRefreshDirectory] {
        // openat + O_NOFOLLOW and descriptor reads avoid following a swapped
        // request file. The extension owns this small, private directory.
        let directoryFD = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { return [] }
        defer { close(directoryFD) }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0,
              directoryInfo.st_uid == geteuid(), directoryInfo.st_mode & 0o077 == 0 else { return [] }

        guard let directoryStream = fdopendir(dup(directoryFD)) else { return [] }
        defer { closedir(directoryStream) }
        // Cleanup is opt-in because an older extension can replace its file
        // without locking. A busy publisher never delays observation reads.
        let publicationLock = openat(directoryFD, ".publication.lock", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        defer { if publicationLock >= 0 { close(publicationLock) } }
        var lockInfo = stat()
        let canPrune = publicationLock >= 0 && fstat(publicationLock, &lockInfo) == 0
            && lockInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && lockInfo.st_uid == geteuid() && lockInfo.st_mode & 0o077 == 0 && lockInfo.st_nlink == 1
            && svnDockFlock(publicationLock, LOCK_EX | LOCK_NB) == 0
        defer { if canPrune { _ = svnDockFlock(publicationLock, LOCK_UN) } }
        var inspectedExpired = 0
        var expiredCount = 0
        // Finder processes leave small hints behind after an unclean exit.
        // Select recent metadata before decoding, so old files cannot occupy a
        // fixed prefix forever. Never unlink a concurrently replaced request.
        var candidates: [(name: String, id: UUID, modifiedAt: TimeInterval)] = []
        while let item = readdir(directoryStream) {
            let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(5))) else { continue }
            var metadata = stat()
            guard fstatat(directoryFD, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
                  metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  metadata.st_uid == geteuid(), metadata.st_mode & 0o077 == 0,
                  metadata.st_size > 0, metadata.st_size <= Self.maximumRequestBytes else { continue }
            let modified = TimeInterval(metadata.st_mtimespec.tv_sec) + TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
            let expired = metadata.st_nlink == 1 && now.timeIntervalSince1970 - modified > Self.requestLifetime
            if expired { expiredCount += 1 }
            if canPrune, expired, expiredCount > cleanupOffset, inspectedExpired < 128 {
                inspectedExpired += 1
                let descriptor = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                if descriptor >= 0 {
                    let data = Self.readPrivateRequest(descriptor)
                    close(descriptor)
                    if let data, let request = try? Self.decode(data), request.schemaVersion == 1,
                       request.publicationVersion == 1, request.id == id,
                       now.timeIntervalSince(request.updatedAt) > Self.requestLifetime {
                        // Version 1 writers share this lock and atomically
                        // replace immutable files; legacy requests stay intact.
                        var current = stat()
                        if fstatat(directoryFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                           current.st_dev == metadata.st_dev, current.st_ino == metadata.st_ino,
                           unlinkat(directoryFD, name, 0) == 0 { continue }
                    }
                }
            }
            candidates.append((name, id, modified))
            candidates.sort { $0.modifiedAt > $1.modifiedAt }
            if candidates.count > 64 { candidates.removeLast() }
        }
        if canPrune {
            // Rotate past retained legacy hints so they cannot permanently
            // occupy the bounded cleanup window after many Finder restarts.
            cleanupOffset += inspectedExpired
            if cleanupOffset >= expiredCount { cleanupOffset = 0 }
        }
        var requests: [FinderBadgeRefreshRequest] = []
        for candidate in candidates {
            let descriptor = openat(directoryFD, candidate.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            let data = Self.readPrivateRequest(descriptor)
            close(descriptor)
            guard let data, let request = try? Self.decode(data), request.schemaVersion == 1,
                  request.id == candidate.id, request.directories.count <= Self.maximumDirectoriesPerRequest,
                  request.directories.reduce(0, { $0 + $1.itemPaths.count }) <= 2_048,
                  now.timeIntervalSince(request.updatedAt) >= -5,
                  now.timeIntervalSince(request.updatedAt) <= Self.requestLifetime else { continue }
            requests.append(request)
        }

        let roots = registeredRoots.filter(\.enabled)
        var seen = Set<FinderBadgeRefreshDirectory>()
        var result: [FinderBadgeRefreshDirectory] = []
        for request in requests.sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(Self.maximumActiveProcesses) {
            for directory in request.directories {
                guard let rootPath = Self.normalizedPath(directory.workingCopyRoot),
                      let path = Self.normalizedPath(directory.directoryPath),
                      let deepest = roots.filter({ Self.contains(path, root: $0.path) }).max(by: { $0.path.count < $1.path.count }),
                      deepest.id == directory.workingCopyID,
                      Self.normalizedPath(deepest.path) == rootPath else { continue }
                let preferred = Array(Set(directory.itemPaths.compactMap(Self.normalizedPath).filter {
                    URL(fileURLWithPath: $0).deletingLastPathComponent().path == path
                })).sorted()
                let value = FinderBadgeRefreshDirectory(workingCopyID: deepest.id, workingCopyRoot: rootPath, directoryPath: path, itemPaths: preferred)
                if seen.insert(value).inserted { result.append(value) }
            }
        }
        return result
    }

    private static func readPrivateRequest(_ descriptor: Int32) -> Data? {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= maximumRequestBytes else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size) + 1)
        let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        guard count == info.st_size else { return nil }
        return Data(bytes.prefix(Int(count)))
    }

    private static func decode(_ data: Data) throws -> FinderBadgeRefreshRequest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO-8601 date")
            }
            return date
        }
        return try decoder.decode(FinderBadgeRefreshRequest.self, from: data)
    }

    private static func normalizedPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func contains(_ path: String, root: String) -> Bool {
        guard let root = normalizedPath(root) else { return false }
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
