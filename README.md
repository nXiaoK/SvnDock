# SvnDock

[简体中文](README.zh-CN.md)

![Version](https://img.shields.io/badge/version-0.3.0-blue)
![macOS](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift toolchain](https://img.shields.io/badge/Swift_6-toolchain-orange?logo=swift)
![License](https://img.shields.io/badge/license-MIT-green)

SvnDock is a native macOS Subversion client focused on multiple working copies
and Finder integration. It keeps common SVN operations close to the files while
remaining independent of an IDE. A directory may also contain a Git repository:
SvnDock does not invoke Git or intentionally modify `.git`.

> SvnDock is a development preview. Version 0.3.0 supports the main working-copy
> workflows and a Finder Sync extension, but there is no Developer ID-signed or
> notarized public binary yet. Build the app locally before evaluating it.

## Highlights

- Register multiple SVN working copies with no application-imposed limit.
- View local status, filter changed paths, inspect text diffs and browse
  repository history.
- Single-click a file to update the diff inspector immediately; double-click
  to open its diff in a separate window. Command/Shift multiselection and
  keyboard navigation remain available.
- Switch between unified, side-by-side and raw diffs with actual file line
  numbers, hunk navigation, automatic wrapping, full-patch copying and 10–20 pt
  text sizing. The inspector and standalone window share the same viewer.
- Expand commit diffs with **放大查看** (Shift-Command-F) to read changes and
  navigate files. **返回提交** or Escape returns to the draft with its message
  and file selection preserved.
- Select a history entry to browse its changed paths and historical diffs, or
  double-click for a larger commit detail window. Added/deleted/replaced paths,
  copy/move ancestry, directory properties and binary output are supported.
- Run Update, Commit, Add, Revert, Resolve, Cleanup and safe `svn:ignore`
  workflows.
- Use Finder contextual menus for frequent operations.
- Display Finder badges from cached status without running SVN inside Finder.
- Serialize mutations per working copy, including coordination between the app
  and the optional Agent executable.
- Execute SVN through `Foundation.Process` with an argument array rather than a
  shell.
- Leave authentication to the installed SVN client and its configuration;
  SvnDock does not accept or persist passwords.

Changing a preview selection cancels obsolete diff work. Large status and diff
views reuse their data, and Finder reuses unchanged cached snapshots. See the
[code audit and measured performance results](Docs/Audit-2026-09/README.md)
for the workloads, verification and remaining memory limits.

Large commits use a temporary targets file and remain a single SVN transaction.
Missing files are excluded from the commit checklist: restore the file, cancel
its pending addition, or schedule its deletion as appropriate before retrying.
Committing a directory still includes its descendants, which may contain missing
files. SvnDock does not automatically change their add/delete schedules.

If a directory was added locally, never committed, then deleted from disk, use
**Clean uncommitted addition records** in the missing-items banner (or the
directory's context menu). SvnDock verifies that the selected roots are missing
pending additions before cancelling their schedules recursively. It does not
delete disk contents or commit repository changes. Missing versioned items block
the cleanup; select only the intended pending additions in that case. Missing
subtrees are grouped by default; use **Show details** or search to inspect them.

## Compatibility

| Component | Support |
| --- | --- |
| macOS | 14 or later |
| Apple Silicon | Tested |
| Intel Mac | The local builder supports `x86_64`, but has not been tested on physical Intel hardware |
| Subversion | Tested with SVN 1.14; other versions are not yet verified |
| User interface | Simplified Chinese |
| Distribution | Source build and local ad-hoc test build |

SvnDock looks for `svn` in common Homebrew, MacPorts and system locations, then
checks `PATH`. Advanced development setups can set `SVNDOCK_SVN_PATH` to an
absolute executable path.

## Build a local app

Prerequisites:

- Apple Command Line Tools with a Swift 6-capable macOS SDK
- Subversion installed locally

From the repository root:

```sh
./Scripts/build-local-signed-app.sh ./dist
```

The script creates `dist/SvnDock.app` and an archive for the current
architecture. Both the app and Finder extension are ad-hoc signed with Hardened
Runtime enabled.

This output is a local test build, not a distributable release. It has no
publisher identity, provisioning profile or notarization ticket, and its shared
data path is sealed for the account that built it. Build it from source on the
Mac account where it will run. See
[Local ad-hoc build](Docs/Local-Signed-Build.md) for the security and signing
details.

### Enable the Finder extension

1. Move the locally built `SvnDock.app` to `/Applications` and open it once.
2. On macOS 15, go to **System Settings → General → Login Items & Extensions →
   Extensions → Finder Extensions**.
3. On macOS 14, the Finder extension may instead appear under **Privacy &
   Security → Extensions**.
4. Enable **SvnDock Finder**, open SvnDock and register an existing SVN working
   copy.

Keep only one discoverable copy of the app. If Finder retains an older extension
instance, toggle the extension off and on before restarting Finder.

## Development

### Swift Package Manager

```sh
swift build --disable-sandbox
swift test --disable-sandbox
swift run --disable-sandbox SvnDockCoreSmoke
```

`swift test` requires a toolchain that provides XCTest. The smoke executable
does not access a real repository unless a disposable integration working copy
is explicitly supplied through its documented environment variables.

### Xcode project

The Xcode project is generated from `project.yml`:

```sh
xcodegen generate
open SvnDock.xcodeproj
```

Before signing, replace these settings in `project.yml` with identifiers owned
by your Apple Developer team:

```yaml
SVNDOCK_BUNDLE_ID_PREFIX: com.yourcompany.svndock
SVNDOCK_APP_GROUP_IDENTIFIER: group.com.yourcompany.svndock.shared
```

The app and Finder extension must use the same provisioned App Group. The
Developer ID, App Group and notarization path is the intended distribution
setup, but has not yet been validated as a public release pipeline.

## Repository layout

```text
SvnDockCore/       SVN commands, XML parsing, process execution and shared state
SvnDockCoreTests/  Core XCTest suite
SvnDockCoreSmoke/  Dependency-free smoke checks
SvnDockApp/        SwiftUI application
FinderExtension/   Finder Sync menus, badges and command enqueueing
SvnDockAgent/      Background consumer prototype; not embedded in the app
Docs/              Architecture and local-build documentation
Scripts/           Local app assembly script
Packaging/         Entitlements used by the local builder
project.yml        XcodeGen project definition
```

The process boundaries and command ownership model are described in
[Architecture](Docs/Architecture.md).

## Known limitations

- Existing working copies can be registered; checkout and import flows are not
  implemented.
- The background Agent is built and tested as a separate executable, but is not
  embedded or registered with `SMAppService`. Finder commands are currently
  consumed by the foreground app.
- There is no built-in credentials editor. Authentication behavior belongs to
  the installed SVN client.
- Finder controls extension lifetime, menu placement and badge arbitration.
  Other Finder extensions may override the same badges.
- A portable, Developer ID-signed and notarized release is not available yet.

## Contributing and security

Bug reports and focused pull requests are welcome. Read
[CONTRIBUTING.md](CONTRIBUTING.md) before making a change. Please report
security-sensitive issues using the private process in
[SECURITY.md](SECURITY.md), not a public issue.

The planned work is tracked in [ROADMAP.md](ROADMAP.md), and user-visible
changes are recorded in [CHANGELOG.md](CHANGELOG.md).

## License

SvnDock is available under the [MIT License](LICENSE).
