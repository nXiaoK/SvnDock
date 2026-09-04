# Contributing to SvnDock

Thank you for helping improve SvnDock. Small, focused changes with a clear
reason and reproducible verification are the easiest to review.

## Before you start

- Search existing issues before opening a new one.
- Use an issue to discuss large UI changes, new dependencies, storage-format
  changes or changes to the Finder/App security boundary.
- Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Development environment

SvnDock requires macOS 14 or later. The tested development setup uses:

- a Swift 6 toolchain;
- full Xcode for XCTest, Finder extension and signing work;
- Subversion 1.14 for integration testing;
- XcodeGen when generating `SvnDock.xcodeproj`.

The package currently compiles in Swift 5 language mode while enabling strict
concurrency checks in release verification.

## Build and test

Run these checks from the repository root:

```sh
swift build --disable-sandbox -c release \
  -Xswiftc -swift-version -Xswiftc 6 \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
swift test --disable-sandbox
swift run --disable-sandbox -c release \
  -Xswiftc -swift-version -Xswiftc 6 \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors \
  SvnDockCoreSmoke
plutil -lint \
  SvnDockApp/Resources/Info.plist \
  FinderExtension/Info.plist \
  SvnDockAgent/Info.plist
```

Real SVN integration checks must use a disposable repository and working copy.
Never point a destructive test at a production working copy.

## Pull requests

1. Create a branch from `main`.
2. Keep the change focused and include tests for behavior in `SvnDockCore`.
3. Preserve the Finder boundary: the extension must not run SVN, perform
   network work or handle credentials.
4. Do not use shell command construction for SVN. Pass an executable URL and
   argument array through the existing process layer.
5. Update both READMEs when user-facing behavior or requirements change.
6. Include verification steps and screenshots for visible UI changes.

Logs, fixtures and screenshots must be scrubbed of credentials, repository
URLs, account names and personal filesystem paths.

By submitting a contribution, you agree that it may be distributed under the
repository's [MIT License](LICENSE).
