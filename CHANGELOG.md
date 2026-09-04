# Changelog

Notable user-facing changes to SvnDock are recorded here. This project follows
[Semantic Versioning](https://semver.org/) while it is in active development.

## [Unreleased]

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
