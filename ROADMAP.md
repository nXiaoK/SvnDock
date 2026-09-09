# Roadmap

SvnDock is developed in small, testable increments. This roadmap describes
direction, not a release commitment.

## Distribution readiness

- Add an application icon and release-quality onboarding.
- Validate Developer ID signing, App Group provisioning, notarization and
  stapling in a repeatable release workflow.
- Publish checksums and signature verification instructions with the first
  portable release.
- Validate the local and formal build paths on physical Intel hardware.

## Finder and background operation

- Embed the Agent in the signed application and manage it through
  `SMAppService`.
- Validate launch, upgrade, crash recovery and App/Agent handoff behavior using
  a provisioned App Group.
- Add automatic repair for stale Finder badge snapshots.

## Working-copy workflows

- Add repository import.
- Add revision-to-revision diff and richer log details.
- Improve conflict inspection and recovery guidance.
- Add optional English UI localization and accessibility review.

Priorities may change based on reproducible bug reports and contributor
interest.
