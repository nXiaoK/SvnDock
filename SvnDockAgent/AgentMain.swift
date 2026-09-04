import Darwin
import Foundation
import SvnDockCore

@main
struct AgentMain {
    static func main() async {
        do {
            let store = try makeStore()
            try store.prepareDirectories()

            let coordinator = try FinderCommandQueueCoordinator(
                directoryURL: store.baseDirectoryURL
            )
            try await coordinator.prepareDirectories()
            guard let consumerLease = try await coordinator.acquireConsumerLease(
                for: .agent
            ) else {
                // A healthy Agent already owns this App Group queue.
                return
            }
            _ = try await coordinator.recoverOrphanedClaims(
                for: .agent,
                lease: consumerLease
            )

            let processor = try FinderCommandQueueProcessor(
                store: store,
                coordinator: coordinator,
                consumerLease: consumerLease,
                executor: try makeExecutor(
                    baseDirectoryURL: store.baseDirectoryURL
                )
            )
            let runOnce = CommandLine.arguments.contains("--once")

            repeat {
                let summary = await processor.processAvailableCommands()
                if runOnce { break }

                // Be responsive while draining a backlog and economical while
                // idle. No repository output or credentials are logged.
                let delay: Duration = summary.madeProgress
                    ? .milliseconds(200)
                    : .seconds(1)
                try await Task.sleep(for: delay)
            } while !Task.isCancelled
        } catch is CancellationError {
            return
        } catch {
            // launchd/SMAppService observes the nonzero status. Details belong
            // in bounded diagnostics, not stdout/stderr where secrets may leak.
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func makeStore() throws -> AgentQueueStore {
        let environment = ProcessInfo.processInfo.environment

        #if DEBUG
        if let override = environment["SVNDOCK_SHARED_DIRECTORY"], !override.isEmpty {
            guard override.hasPrefix("/"), !override.contains("\0") else {
                throw AgentQueueStoreError.invalidContainerPath
            }
            return try AgentQueueStore(
                baseDirectoryURL: URL(fileURLWithPath: override, isDirectory: true)
            )
        }
        #endif

        return try AgentQueueStore(
            appGroupIdentifier: try configuredAppGroupIdentifier()
        )
    }

    private static func configuredAppGroupIdentifier(
        bundle: Bundle = .main
    ) throws -> String {
        let key = "SvnDockAppGroupIdentifier"
        let configured = (bundle.object(
            forInfoDictionaryKey: key
        ) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let configured,
           configured.hasPrefix("group."),
           configured.count > "group.".count,
           !configured.contains("$(") {
            return configured
        }

        #if DEBUG
        // SwiftPM Debug executables do not process the Xcode Info.plist.
        return AgentQueueStore.defaultAppGroupIdentifier
        #else
        throw AgentConfigurationError.invalidAppGroupIdentifier(key: key)
        #endif
    }

    private static func makeExecutor(
        baseDirectoryURL: URL
    ) throws -> any FinderCommandExecuting {
        try SvnDockCoreCommandExecutor(baseDirectoryURL: baseDirectoryURL)
    }
}

private enum AgentConfigurationError: LocalizedError, Sendable {
    case invalidAppGroupIdentifier(key: String)

    var errorDescription: String? {
        switch self {
        case .invalidAppGroupIdentifier(let key):
            return "The Release build is missing a valid \(key)."
        }
    }
}
