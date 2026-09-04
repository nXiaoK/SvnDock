import Foundation
import SvnDockCore

public struct AgentRegisteredRootsDocument: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let roots: [AgentRegisteredRoot]
}

public struct AgentRegisteredRoot: Codable, Hashable, Sendable {
    public let id: UUID
    public let path: String
    public let displayName: String?
    public let enabled: Bool

    public var standardizedURL: URL? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}

/// A command that has passed registry, path-component, and symlink-boundary
/// validation. Executors must still rely on SvnDockCore's argv validation.
public struct ValidatedFinderCommand: Sendable {
    public let request: FinderCommand
    public let registeredRoot: AgentRegisteredRoot
    public let workingCopyURL: URL
    public let selectedURLs: [URL]

    public var id: UUID { request.id }
    public var kind: FinderCommandKind { request.kind }
}

public enum AgentFailureCategory: String, Codable, Sendable {
    case invalidRequest
    case registryUnavailable
    case requiresMainApplication
    case executionFailed
    case internalFailure
}

public struct AgentFailureDiagnostic: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let requestID: UUID
    public let category: AgentFailureCategory
    public let summary: String
    public let attempts: Int
    public let lastAttemptAt: String
    public let nextAttemptAt: String?
    public let retryable: Bool

    public init(
        requestID: UUID,
        category: AgentFailureCategory,
        summary: String,
        attempts: Int,
        lastAttemptAt: Date,
        nextAttemptAt: Date?,
        retryable: Bool
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.requestID = requestID
        self.category = category
        self.summary = summary
        self.attempts = attempts
        self.lastAttemptAt = AgentTimestamp.string(from: lastAttemptAt)
        self.nextAttemptAt = nextAttemptAt.map(AgentTimestamp.string(from:))
        self.retryable = retryable
    }
}

public enum AgentTimestamp {
    public static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    public static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

public struct QueueProcessingSummary: Sendable, Equatable {
    public var completed = 0
    public var handedOff = 0
    public var rejected = 0
    public var quarantined = 0
    public var failed = 0
    public var skipped = 0

    public init(
        completed: Int = 0,
        handedOff: Int = 0,
        rejected: Int = 0,
        quarantined: Int = 0,
        failed: Int = 0,
        skipped: Int = 0
    ) {
        self.completed = completed
        self.handedOff = handedOff
        self.rejected = rejected
        self.quarantined = quarantined
        self.failed = failed
        self.skipped = skipped
    }

    public var madeProgress: Bool {
        completed + handedOff + rejected + quarantined + failed > 0
    }

    public static func + (left: Self, right: Self) -> Self {
        Self(
            completed: left.completed + right.completed,
            handedOff: left.handedOff + right.handedOff,
            rejected: left.rejected + right.rejected,
            quarantined: left.quarantined + right.quarantined,
            failed: left.failed + right.failed,
            skipped: left.skipped + right.skipped
        )
    }
}
