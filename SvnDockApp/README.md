# SvnDockApp integration notes

This directory contains the native macOS SwiftUI application target. It is
designed around an injectable `SvnDockServicing` boundary:

- `CoreSvnDockService` is the production adapter for `SvnDockCore`.
- `MockSvnDockService.preview()` supplies deterministic previews and UI tests.
- `SvnDockStore` owns selection, filtering, operation state and error handling.

The application supports multiple registered working copies, status/search
filters, a file list, diff/information/history inspectors, directory
registration, update, commit, add, revert, conflict resolution, `svn:ignore`,
and cleanup entry points. Registration and badge snapshots use
`FinderSharedStore`, so the app and Finder Sync extension share one source of
truth.

## Xcode target settings

The repository-level `project.yml` already applies these settings when the
Xcode project is generated. If the target is wired manually, keep the same
configuration:

1. Add every `.swift` file below `SvnDockApp/` to the `SvnDock` macOS app
   target and link the `SvnDockCore` target.
2. Set the deployment target to macOS 14.0 or newer.
3. Set `INFOPLIST_FILE` to `SvnDockApp/Resources/Info.plist` and
   `CODE_SIGN_ENTITLEMENTS` to
   `SvnDockApp/Resources/SvnDock.entitlements`.
4. When using XcodeGen, set `SVNDOCK_BUNDLE_ID_PREFIX` and
   `SVNDOCK_APP_GROUP_IDENTIFIER` once in the root `project.yml`. For a manually
   created Xcode project, define those custom build settings in Xcode or an
   xcconfig instead—manual targets do not read `project.yml`. The Info plist and
   entitlements consume the App Group setting; do not edit their expanded
   values separately.
5. Keep App Sandbox disabled for the current distribution model. A sandboxed process cannot execute
   `/opt/homebrew/bin/svn`; a future sandboxed distribution must bundle and sign
   the SVN runtime instead.
6. Enable Hardened Runtime and notarize Developer ID release archives.

Debug SwiftPM runs and SwiftUI previews cannot resolve an App Group container.
For those development modes only, `SvnDockAppEnvironment` uses the development
identifier and falls back to `~/Library/Application Support/SvnDock`. Release
builds reject a missing, empty, or unexpanded `SvnDockAppGroupIdentifier`, and
real Xcode builds fail visibly if the signed App Group is unavailable. This
prevents a silent split-brain state with Finder.

## Security behavior

SVN credentials are never accepted or persisted by the UI. The command builder
passes no password on argv and lets the installed SVN client use its existing
macOS Keychain/configuration. Selected paths are normalized by `SvnDockCore`
before any command is launched.

Conflict and ignore actions freeze their working-copy/path targets before
confirmation closes. Ignore values are merged with the existing property under
one scheduler lease and delivered over stdin. An exact directory status row is
reverted at depth `empty`, so reverting `svn:ignore` cannot recursively discard
unrelated child edits.
