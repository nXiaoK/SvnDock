# Security policy

## Supported code

SvnDock is a development preview without a stable release support window.
Security fixes are made on the latest `main` branch. Older snapshots may not
receive updates.

## Reporting a vulnerability

Do not disclose a suspected vulnerability in a public issue, discussion or pull
request.

Use GitHub's
[private vulnerability reporting](https://github.com/nXiaoK/SvnDock/security/advisories/new)
when it is available. If that form is unavailable, open a public issue that
contains no sensitive details and asks the maintainer for a private contact
channel.

Include only the information needed to reproduce and assess the issue:

- affected commit or version;
- macOS version and CPU architecture;
- impact and prerequisites;
- minimal reproduction steps;
- a proposed mitigation, if known.

Remove credentials, repository URLs, usernames, working-copy contents and
absolute personal paths from all reports. Reports will be assessed on a
best-effort basis; avoid publishing details until a fix or coordinated
disclosure plan is agreed.

## Release-signing status

The repository does not currently provide a Developer ID-signed and notarized
binary. The local build script creates an ad-hoc signed test app and does not
establish publisher identity. Treat binaries from any other source as
unofficial unless this policy and the repository's release notes say otherwise.
