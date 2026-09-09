# Changelog

Notable user-facing changes to SvnDock are recorded here. This project follows
[Semantic Versioning](https://semver.org/) while it is in active development.

## [Unreleased]

### Added

- Preview the final SVN commit command from the commit sheet using its checked
  paths and current message. Show the working directory, stdin and complete
  targets-file contents, with copy support and no SVN execution.

- Check out a repository URL into a new or empty local directory, with live
  progress, cancellation, retry and automatic working-copy registration.
  Downloads are verified before publication; existing files and paths created
  during checkout are never overwritten.

- Restore one versioned file to the state before a specified revision from
  SvnDock or Finder. Preview the rN-1 target, restore content and properties as
  local changes, and reject stale previews or uncommitted edits. Supports
  binary files, literal special-character filenames and copy/rename ancestry.

- Conflict review sheets show exact paths, conflict types, current diffs and
  strategy-specific guidance. Whole-file replacement requires explicit consent;
  mixed selections preserve their eligible conflict subset. Resolve outcomes
  join session operation records with scope and verification details.
- Filter loaded history by message, author and revision, combine an author
  condition, and open a repository revision directly without paging to it.
  Older-revision pagination replaces repeated HEAD queries and the 1,000-entry
  cap; failed pages preserve rows and retry their original range.
  Compact inspectors show a focused revision detail with return navigation,
  preserving the filtered list and selection when space is limited.
- Session operation records retain the latest 30 Update and Commit outcomes,
  with per-working-copy details and credential redaction before display or copying.
  Multi-copy updates continue after individual failures; cancellation stops the
  remaining copies. Uncertain commit outcomes retain drafts and advise checking
  repository history before retrying.
- Explicit server-update checks show incoming content and property paths in a
  separate snapshot, with timestamps, stale-result indicators and retry feedback.
  Working-copy headers distinguish repository URLs, local paths and root baselines.
- Read-only previews for unversioned UTF-8 files, local directory property diffs,
  persistent diff reading preferences and multi-selection action summaries.
- Working-copy-specific commit drafts survive closing and restarting, with path
  filtering, inclusion filtering and explicit clearing of message and selection.
- Independent Settings switches for launch at login and menu bar visibility.
  Login Items use macOS registration state with approval and error feedback.
  The menu bar provides cached working-copy status, navigation, refresh,
  update, commit, history, Finder, Settings and main-window access. Reopening
  the main window preserves workspace state without duplicate startup scans.
- Commit diffs expand into a focused reading layout with file navigation.
  Return or Escape restores the commit form, draft and file selection.
  Diff text size can be adjusted from 10 to 20 pt.
- Select a revision to browse its changed paths and preview historical diffs;
  double-click to open a larger commit detail window. Supports path search,
  copy/move ancestry, deleted/replaced files, implicit directory descendants,
  properties, binary output, bounded caching and stale-request cancellation.
- Shared unified/side-by-side diff viewer with actual old/new line numbers,
  change counts, hunk navigation, automatic line wrapping and raw patch copying.
- Missing files from deleted, uncommitted additions can be cleared from the
  status banner, inspector or context menu. SVN scheduling is verified before
  cancelling the addition, and missing versioned files are rejected.
- Missing subtrees are grouped under their parent directory by default, with
  counts, a detail toggle and full-path search.

### Fixed

- Use one system file picker for working-copy registration and historical file
  selection, so adding a working copy opens its directory dialog again.
  Cancellation, errors and stale callbacks cannot leave the main window locked.

- Resolve checks the selected nodes again under the working-copy lock before
  reporting completion. Shallow execution leaves unselected child conflicts
  intact and rejects external or nested working copies and escaping symlinks.
  Failed verification is reported explicitly without automatically retrying.
- Context-menu Add and Revert preserve selected groups and explain eligible
  subsets. Revert confirmation identifies the captured paths and directory scope.
- Selected commits keep directory property changes shallow, validate required
  added parents and current SVN status, and reject file externals before writing.
  Directory copy/delete scope is explained without including unselected local edits.
- History selection uses soft blue cards and readable text in light and dark
  appearances, matching the workspace while retaining native list interaction.
- History entries and their changed paths update the embedded preview on a
  single click, while double-click still opens a larger commit detail window.
- Missing versioned files and directories can be scheduled for SVN deletion
  and then committed. Context menus distinguish these from uncommitted
  additions, preserve multiselection and check current SVN schedules before
  changing them. Revert restores missing/deleted directory contents while
  keeping ordinary property-only directory reverts shallow.
- File rows update the diff inspector on a single click. Native list actions
  preserve double-click opening, directory expansion and Command/Shift selection.
- Custom buttons respond across their full visible bounds, including padding,
  with consistent hover, pressed and disabled feedback.
- Diff panes fill their available space from the top. Equal-width columns and
  aligned row heights prevent large gaps, clipped content and missing hunks.
- Diff reloads reject stale responses when switching files or working copies.
  Windows line endings parse correctly, and property changes remain visible
  alongside text changes.
- App icons retain transparent margins at every resolution, removing the white
  square around the rounded icon in the Dock and Finder.
- Large commits use a temporary targets file instead of exceeding macOS process
  argument limits and crashing. Process invocations also validate argument
  count and size before launch.
- Missing files are no longer offered for commit. The app explains how to
  handle missing additions, and selecting only ineligible files no longer
  preselects unrelated changes in the commit sheet.
- SVN commands use a UTF-8 locale so Chinese filenames and commit messages
  are preserved.

## [0.3.0] - 2026-09-04

### Added

- Native SwiftUI working-copy browser with status filtering, text diff,
  repository information and paged history.
- Update, Commit, Add, Revert, Resolve, Cleanup and `svn:ignore` workflows.
- Finder Sync contextual menus and cached status badges for multiple registered
  working copies.
- Shared command queue with durable receipts, duplicate-request handling and
  uncertain-outcome quarantine.
- Per-working-copy scheduling and cross-process locking.
- Experimental background Agent executable with a restricted automatic-command
  allowlist. The Agent is not embedded in the app.
- Local ad-hoc app builder for development and Finder extension testing.

### Security

- SVN commands use an absolute executable and argument array without invoking a
  shell.
- Selected paths are normalized and checked against their registered
  working-copy root before execution.
- Finder never runs SVN or handles repository credentials.
