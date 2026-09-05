# Changelog

Notable user-facing changes to SvnDock are recorded here. This project follows
[Semantic Versioning](https://semver.org/) while it is in active development.

## [Unreleased]

### Added

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
