# SvnDock Agent

`SvnDockAgent` is the background half of the shared App/Agent Finder-command
protocol. It can run once for tests (`--once`) or poll as a long-lived helper.
The source is implemented and testable, but the current app does **not** embed,
launch, or register it with `SMAppService`; Finder requests in the generated
product are still consumed by the foreground App.

## Responsibilities and safety boundary

- Hold the process-lifetime `.agent` consumer lease before recovery or claims.
  A second Agent exits without touching the live owner's files.
- Delegate ownership transitions to
  `SvnDockCore.FinderCommandQueueCoordinator`, using a random claim token,
  owner-specific processing files, atomic renames, and durable receipts.
- Accept schema version 1, source `finder-extension`, a fresh creation time, and
  bounded non-duplicate paths only.
- Reload the enabled working-copy registry, require the exact registered root,
  and revalidate membership and symlink boundaries immediately before mutation.
- Require the root directory and its `.svn` administrative directory to exist.
- Use `CrossProcessWorkingCopyLock` so App and Agent cannot run SVN concurrently
  for the same registered working-copy UUID.
- Never use a shell. `SVNCommandBuilder` and `ProcessRunner` pass an argv array
  directly to `Foundation.Process`.
- Never persist argv, environment, stdout, stderr, repository output, or
  credentials. Durable diagnostics contain only bounded category/status text.

The strict automatic allowlist is root `update`, selected-path `add`, and root
`cleanup`. Commit, revert, resolve, diff, log, ignore, copy-URL, refresh,
open-app, and path-scoped Update/Cleanup requests are atomically moved to
`command-app-inbox` for the App. A distributed notification is a best-effort
wake-up only; the inbox file is the durable handoff.

## Queue lifecycle

Relative to `Library/Application Support/SvnDock` in the App Group container:

```text
command-queue/                  Finder-created pending requests
command-app-inbox/              durable Agent-to-App handoff
command-processing/agent/       tokenized claimed/executing Agent files
command-processing/application/ tokenized App files
command-receipts/               completed/cancelled/rejected terminal records
command-uncertain/              executing claims with unknown outcomes
command-dead-letter/            malformed owned files
consumer-locks/agent.lock       process-lifetime singleton lease
command-state.lock              cross-directory state serialization
command-failures/               bounded safe diagnostics
```

The Agent advances a validated background request from `claimed` to
`executing` before calling SVN. Success writes a durable completed receipt
before removing the claim. A failed or cancelled executing request is moved to
`command-uncertain` and never returned to the pending queue because SVN may have
already produced side effects.

At startup, recovery requires the Agent lease. Pre-execution Agent claims are
safe to release; executing claims without a matching receipt are quarantined.
If a receipt was persisted just before claim deletion failed, recovery verifies
its command, owner, and token before deleting only the leftover processing
file.

Registry-read failures may release a request before execution and use a bounded
exponential retry delay. Invalid or expired requests receive a rejected
terminal result. Non-sensitive failure diagnostics never substitute for queue
ownership.

## Badge refresh after mutation

The cross-process working-copy lock remains held across the SVN mutation, a
complete local `svn status --xml`, status parsing, and replacement of that
working copy's Finder badge slice. The badge write validates both registered
UUID and canonical path, preserves independently registered nested roots, and
posts `com.svndock.shared-state-changed` after success.

If the mutation succeeds but status/badge refresh fails, the Agent writes one
atomically replaced `badge-refresh-dirty/<working-copy-uuid>.json` marker. It
does not fail the completed mutation or make the command replayable. A later
successful Agent refresh clears the marker.

## Xcode integration

The current `project.yml` defines a command-line `tool` target so the Agent and
its `SvnDockCoreCommandExecutor` can be compiled and tested. It intentionally
does not embed or register that product, and excludes the Agent Info plist and
entitlements from the current product until the `SMAppService` packaging path
is validated.

For a production package, convert it to an embedded background helper, use
`Info.plist` and `SvnDockAgent.entitlements`, and let both expand
`SVNDOCK_APP_GROUP_IDENTIFIER` from the root `project.yml`, the same value used
by the main app and Finder extension. If the helper target is created manually
instead of with XcodeGen, define the custom settings in Xcode or an xcconfig
because `project.yml` is not loaded.

Embed the helper under the main app, sign it with the same team, and register it
from the main app with `SMAppService`. The raw LaunchAgent example only
documents a development/distribution fallback path; that embedded executable
path is **not** produced by the current `type: tool` target. Do not load or
distribute it as though the helper were already installed.

For unsigned Debug tests only, `SVNDOCK_SHARED_DIRECTORY` may point directly to
an absolute App Group-equivalent shared directory. Release builds do not honor
this override and reject a missing, empty, or unexpanded
`SvnDockAppGroupIdentifier`; production must use the signed App Group
entitlement.
