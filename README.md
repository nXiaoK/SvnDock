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
> workflows and a Finder Sync extension. [GitHub Releases](https://github.com/nXiaoK/SvnDock/releases)
> provides automated arm64 and x64 DMG test builds. These use portable ad-hoc
> signatures; Developer ID signing and Apple notarization are not configured.

## Highlights

- Register multiple SVN working copies with no application-imposed limit.
- Distinguish the local folder, repository URL and root-directory baseline.
  **检查服务器** explicitly checks incoming content and property changes without
  updating files or changing local status/Finder badges. Results retain their
  check time and are marked stale after local refresh or a write workflow.
- Choose launch at login and menu bar visibility independently in Settings.
  The menu bar offers working-copy status, navigation, refresh, update, commit,
  history and quick access to Finder and Settings, even after closing the main window.
- View local status, filter changed paths, inspect text diffs and browse
  repository history.
- Single-click a file to update the diff inspector immediately; double-click
  to open its diff in a separate window. Command/Shift multiselection and
  keyboard navigation remain available.
- Inspect local directory property changes and preview unversioned UTF-8 text
  without adding it first. Local previews are limited to 1 MiB and distinguish
  binary, unsupported, missing and unreadable files. Diff mode and text size persist.
- Context-menu Add and Revert preserve selections and show the affected count;
  the multi-selection inspector summarizes statuses and available actions.
- Switch between unified, side-by-side and raw diffs with actual file line
  numbers, hunk navigation, automatic wrapping, full-patch copying and 10–20 pt
  text sizing. The inspector and standalone window share the same viewer.
- Expand commit diffs with **放大查看** (Shift-Command-F) to read changes and
  navigate files. **返回提交** or Escape returns to the draft with its message
  and file selection preserved.
- Commit drafts retain their message, included paths and preview per working
  copy across closing and restarting. Filter the checklist by path or show only
  included items; new changes do not silently join a saved selection.
- Filter loaded commit records by message, author or revision, combine an author
  condition, or open a repository revision directly with `r123` / `123`.
  History loads 100 records per page using an older-revision cursor, with no
  1,000-record browsing cap; failed reads preserve rows and retry the same page.
- Single-click a history entry to update its changed paths, then single-click
  a changed path to preview its historical diff. Double-click either list to
  open a larger commit detail window. Added/deleted/replaced paths,
  copy/move ancestry, directory properties and binary output are supported.
  Selected history entries and paths use a soft blue background with readable
  text in both light and dark appearances.
- Review exact conflict paths, content/property/tree types and current diffs
  before choosing a resolution. Mixed selections preserve their conflict subset;
  whole-file replacement requires explicit consent and eligible file conflicts.
  Resolve verifies the selected nodes afterward and records incomplete or
  uncertain results without automatically retrying.
- Run Update, Commit, Add, Revert, Resolve, Cleanup and safe `svn:ignore`
  workflows.
- Review the latest 30 Update, Commit and Resolve results from the bottom operation bar
  during the current run, including per-working-copy outcomes and redacted
  copyable details. Multi-copy updates continue after an individual failure.
  Interrupted or unconfirmed commits retain the draft and require checking
  repository history before a manual retry.
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
Selected nodes commit at depth `empty`: directory properties do not include
unselected child edits. Added children require their uncommitted parent
directories to be selected. Directory deletion still removes the repository
subtree, and copied directories retain the source tree and history; their
unselected local child edits remain local. The checklist explains these tree
operations. SVN status and required parent selections are rechecked under the
working-copy lock before one commit transaction. File externals must be handled
separately. SvnDock does not automatically change add/delete schedules.

For an already-versioned file or directory deleted from disk, choose
**标记为 SVN 删除…** (Schedule SVN deletion) in its context menu or inspector.
The action supports multiselection and grouped missing directories. It changes
the local SVN state from missing (`!`) to deleted (`D`); commit that deletion
to remove the path from the repository. Updating a merely missing path can
restore it, whereas updating after the deletion is committed will not.
Revert restores a missing or scheduled-deletion directory and its contents.
Ordinary directory property reverts remain shallow.

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
| Intel Mac | Native `x86_64` CI build and tests; physical Intel desktop UI not yet verified |
| Subversion | Tested with SVN 1.14; other versions are not yet verified |
| User interface | Simplified Chinese |
| Distribution | Source, local test App, and portable arm64/x64 DMG prereleases |

SvnDock looks for `svn` in common Homebrew, MacPorts and system locations, then
checks `PATH`. Advanced development setups can set `SVNDOCK_SVN_PATH` to an
absolute executable path.

## Download and install

Download the matching DMG from [Releases](https://github.com/nXiaoK/SvnDock/releases),
open it, and drag **SvnDock.app** onto **Applications**. Eject the DMG and run
the installed App. SVN 1.14 is a separate runtime prerequisite, for example
`brew install subversion`. Downloaded ad-hoc builds may require explicit macOS
approval before first launch.

Every push builds both architectures and publishes a complete prerelease with
checksums after verification. See [automatic DMG releases](Docs/GitHub-Releases.md)
for build triggers, installation, signing limits, and troubleshooting.

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

SvnDock Settings also has **打开 Finder 扩展设置…** for the system's current
extension management interface. Keep the App running while browsing registered
working copies: green checks mean unchanged, yellow pencils mean modified, red
warnings mean conflicted, and blue plus signs mean added. Gray symbols identify
unversioned, ignored, unknown, or stale states. macOS controls icon placement.

Right-click files in Finder and open **SvnDock** to commit the current selection,
view that file's history, or compare local differences. Finder selection takes
priority over a saved draft's checked files; the commit message is preserved.
History details prefer the requested file within a multi-file revision. Normal
files can show an empty diff, and folder differences show directory properties.
Automatic refresh reads the directories Finder is using without adding all
unchanged files to SvnDock's workspace list. Quitting SvnDock stops background
updates; cached badges become gray after a minute.

Keep only one discoverable copy of the app. If Finder retains an older extension
instance, toggle the extension off and on before restarting Finder.

## Startup and menu bar

Open **SvnDock → Settings → 启动与菜单栏**. **登录时启动** registers the
current app with macOS Login Items and displays its actual system status. If
approval is needed, use the provided link to System Settings. Keep the app in
a stable location, such as `/Applications`, before enabling login startup.

**显示菜单栏图标** is off by default and remembers your choice. Its menu uses
the last loaded working-copy status; **刷新状态** requests a fresh scan. Menu
actions share the main window's operation guards, and **提交…** opens the
existing commit form. Closing and reopening the main window preserves the
current workspace without starting another registration load. No periodic
background scan is added.

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
