# SvnDock architecture

SvnDock is a macOS-native Subversion client focused on unlimited working
copies and safe Finder integration. Git repositories may coexist in the same
directory; SvnDock never invokes Git or mutates `.git`.

This document describes the source architecture and its trust boundaries. The
App/Agent coordination code is implemented, but the Agent is not embedded,
registered, or enabled in the current app product.

## Processes

```text
                         immutable commands
FinderSync.appex ─────────────────────────────────┐
       │                                          ▼
       └──── reads roots and badge snapshot ── App Group storage
                                                  │
                         ┌────────────────────────┴──────────────────────┐
                         ▼                                               ▼
                  SvnDock.app                              SvnDockAgent tool
             UI and confirmations                    safe background allowlist
                         │                                               │
                         └──────── shared WC lock ─── svn CLI ───────────┘
```

- **SvnDock.app** owns working-copy management and all interactive workflows:
  status, diff, paged history, commit selection, update, add, revert, cleanup,
  conflict resolution, `svn:ignore`, and destructive-operation confirmation.
  It is the only Finder-command consumer in the currently generated product.
- **FinderSync.appex** is deliberately thin. It reads cached state, supplies
  contextual menus and badges, and enqueues immutable requests. It never runs
  `svn`, touches credentials, or owns authoritative execution state.
- **SvnDockAgent** implements the future long-lived consumer. Its strict
  background allowlist is root Update, selected-path Add, and root Cleanup.
  Every other command is atomically handed to the App. The executable can run
  with `--once` for tests, but `project.yml` still defines it as an unembedded
  command-line tool and the App does not register it with `SMAppService`.

## Shared storage

The development App Group is `group.com.svndock.shared`. Production builds set
`SVNDOCK_BUNDLE_ID_PREFIX` and `SVNDOCK_APP_GROUP_IDENTIFIER` once in
`project.yml`; plist and entitlements values expand from those settings.

Paths below are relative to `Library/Application Support/SvnDock/` in the App
Group container:

```text
registered-roots.json
badge-snapshot.json
badge-snapshot.lock
operation-locks/
  <working-copy-uuid>.lock
command-queue/
  <request-uuid>.json
command-app-inbox/
  <request-uuid>.json
command-processing/
  application/<request>.<claim-token>.<phase>.json
  agent/<request>.<claim-token>.<phase>.json
command-receipts/
  <request-uuid>.json
command-uncertain/
command-dead-letter/
consumer-locks/
  application.lock
  agent.lock
command-state.lock
command-failures/
badge-refresh-dirty/
```

JSON documents are versioned. Writers use atomic file replacement, and queue
ownership changes use same-volume renames. Snapshots, receipts, diagnostics,
and dirty markers contain no credentials, authorization headers, raw SVN
output, or command environment.

## Finder command ownership

`FinderCommandQueueCoordinator` is the single state machine shared by App and
Agent. A request identifier can have only one effective durable state:

```text
command-queue
    │ atomic claim + random token
    ▼
claimed ───────────────► awaitingUser ───────────────► executing
   │                           │                       │       │
   │ Agent UI handoff          │ cancel/reject         │       │ success
   ▼                           ▼                       │       ▼
command-app-inbox       terminal receipt              │ completed receipt
                                                       │
                                                       │ crash/ambiguous error
                                                       ▼
                                              command-uncertain
```

The actual legal transitions are intentionally narrower than the diagram:

- A Finder request starts as one immutable file in `command-queue`.
- App or Agent obtains a random claim token and atomically renames the file into
  its owner-specific processing directory. `command-state.lock` serializes the
  cross-directory checks, so duplicate physical files with the same request ID
  cannot produce two owners or conflicting terminal results.
- All unowned siblings with that ID are decoded before a capability is issued.
  Identical payloads may collapse behind the durable inbox or pending copy;
  differing or malformed siblings are quarantined before execution. Handoff,
  release, and orphan recovery repeat this comparison so a crash cannot reopen
  a conflict created after claim.
- The Agent claims only the generic queue. The App checks its dedicated inbox
  first, then the generic queue. This lets either process win a safe background
  request while reserving handed-off work for the App.
- Before using confirmation UI, the App advances the claim from `claimed` to
  `awaitingUser`. Immediately before SVN side effects it advances to
  `executing`. Noninteractive routes move directly to `executing`.
- An Agent-owned command outside its background allowlist is moved atomically,
  while still pre-execution, to `command-app-inbox`. A distributed notification
  is only a wake-up hint; the inbox file is the durable handoff. When handling
  the original Finder URL, the App can observe Agent ownership for up to two
  seconds while the handoff completes.
- Completion writes a durable receipt before removing the processing file.
  Receipts bind the complete immutable command, owner, claim token, outcome,
  and completion time. A stale claim cannot acknowledge a newer claim for the
  same request ID.
- `completed`, `cancelled`, and `rejected` receipts are terminal. If receipt
  persistence succeeds but claim cleanup fails, startup recovery verifies the
  matching command/owner/token and finishes only the cleanup.

Each role also holds a process-lifetime nonblocking `flock`: one App consumer
and one Agent consumer may coexist, but two instances of the same role cannot
claim or recover concurrently. Recovery requires that lease. Orphaned
`claimed` and `awaitingUser` files are safe to release; orphaned `executing`
files have an unknown side-effect outcome and are moved to
`command-uncertain`, never replayed automatically. Malformed owned files go to
`command-dead-letter`.

This protocol prevents duplicate automatic execution; it does not prove
whether an externally interrupted SVN operation completed. An uncertain item
must be inspected and resolved deliberately.

## Working-copy execution lock

The in-process `WorkingCopyOperationScheduler` preserves ordering for one
working-copy UUID inside the App. `CrossProcessWorkingCopyLock` provides the
corresponding App/Agent lock at
`operation-locks/<working-copy-uuid>.lock`.

- Acquisition uses `flock(2)` with nonblocking, cancellation-aware polling.
- Lock directories are private (`0700`) and files are private (`0600`). The
  implementation rejects symlinks and checks owner, object type, link count,
  and unsafe write permissions before use.
- Descriptors use `O_CLOEXEC`, so an `svn` child cannot extend the lease. A
  thrown error or process exit closes the descriptor and releases the lock.
- App Core operations take both the in-process scheduler lease and the shared
  filesystem lock. The Agent uses the same filesystem lock for its allowlisted
  commands.
- App status parsing and badge persistence stay inside the lock. For Agent
  mutations, the mutation, a complete local `svn status --xml`, parsing, and
  badge persistence are one locked sequence. This prevents an older status
  result from overwriting badges published after a newer mutation.

Locks are keyed by the registered working-copy UUID. Registry and badge owner
validation separately reject a delayed writer whose UUID has been retired or
replaced at the same path.

## Badge consistency

`badge-snapshot.lock` protects the registered-root ownership check and the
entire read-modify-write of `badge-snapshot.json` across processes. Normal App
and Agent writers replace only one registered working copy's slice and must
provide both its UUID and canonical root path.

The snapshot carries optional `entryOwners` metadata for backward-compatible
ownership tracking. A refresh:

- verifies that UUID and path still name the same enabled registration;
- replaces entries under that root while preserving independently registered
  nested working-copy slices;
- records the owning UUID for every replacement entry;
- prevents delayed unregister cleanup from deleting entries now owned by a
  parent or a newly registered UUID at the same path.

After a successful Agent mutation, the Agent publishes the refreshed snapshot
and posts `com.svndock.shared-state-changed`. If SVN mutation succeeds but the
following status/badge refresh fails, it records one bounded, atomically
replaced `badge-refresh-dirty/<working-copy-uuid>.json` marker and still treats
the mutation as completed. It does not replay the SVN command merely to repair
a cache. A later successful Agent refresh clears the marker; a dedicated
automatic repair pass remains future work.

## SVN execution rules

- Resolve an absolute executable path. Prefer the user setting, then
  `/opt/homebrew/bin/svn`, `/usr/local/bin/svn`, and `/opt/local/bin/svn`.
- Use `Foundation.Process` with an argument array. Never invoke a shell.
- Parse `status`, `info`, and `log` through `--xml`; working-copy log targets use
  an explicit `HEAD:1` range instead of SVN's local-path `BASE:1` default.
  Human-readable localized output is only for progress and diagnostics.
- Validate every target is contained by the configured working-copy root using
  standardized path components and resolved-symlink checks, not string-prefix
  trust.
- Do not read or modify `.svn/wc.db` directly.
- Read existing `svn:ignore` through XML and write merged values through stdin
  while holding one working-copy lease.
- Revalidate resolve/ignore target symlink boundaries and exact SVN status in
  that same lease immediately before writing.
- Revert explicitly selected directory rows at depth `empty`; never interpret a
  property-only row as permission to recursively discard child edits.
- Treat remote status as an explicit network check. A clean local badge does
  not claim the working copy is current with the server.

## Finder behavior

`FIFinderSyncController.directoryURLs` receives every enabled working-copy
root. The extension constructs menus synchronously from snapshots. If a cache
entry is missing or stale, common actions remain available and **Refresh
Status** opens the main app for an authoritative read rather than blocking
Finder on `svn status`.

Finder may recreate an extension `NSMenuItem` across its XPC boundary without
preserving `representedObject`. Every generated SvnDock menu therefore receives
an independent random token stored in the item's standard `tag` and
`identifier` fields. A bounded, expiring token map recovers only that exact
immutable selection; missing, expired, unknown, or conflicting token fields
fail closed. The dispatcher then reloads registration state and validates the
paths/root again before it writes a request.

Cross-working-copy selections may be split only for independent safe commands
such as Update. Commit and destructive commands require one working copy and a
confirmation UI in the main app. History, resolve, and ignore Finder entries
are revalidated against fresh SVN status or a safe path-scoped SVN operation in
the App; Finder badge data is never execution authority.

Finder extensions must be enabled by the user in System Settings. Menu
placement, extension lifetime, and badge coexistence with cloud providers are
controlled by macOS and cannot be guaranteed by the application.

## Deployment status

The local builder can assemble `SvnDock.app` with an embedded Finder
`.appex` using Apple Command Line Tools. Both bundles receive ad-hoc
signatures and Hardened Runtime, and the script verifies the bundle before and
after archiving. This path is intended for development on the account that
performs the build; it does not provide publisher identity, App Group
provisioning, Gatekeeper trust or notarization.

The source-level App/Agent protocol is not the same as an activated background
helper. The Agent remains a separate command-line product: it is not embedded
in the app or registered with `SMAppService`. Finder requests in the current
app product are consumed by the foreground App.

A portable release still requires:

- bundle and App Group identifiers owned by an Apple Developer team;
- an embedded and signed Finder extension;
- Developer ID signing with a secure timestamp;
- notarization, stapling and verification on a clean Mac;
- lifecycle testing for install, upgrade and removal.

The intended first public binary targets macOS 14 or later and uses an installed
SVN client. A future sandboxed Mac App Store build would instead need a signed,
embedded SVN runtime and a separate credential/configuration design.
