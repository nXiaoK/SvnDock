# Portable ad-hoc distribution

The `SVNDOCK_PORTABLE_SIGNED_BUILD` compile flag produces an account-independent
ad-hoc build for downloadable test releases. It is separate from the existing
`SVNDOCK_LOCAL_SIGNED_BUILD` mode; defining both is a compilation error.

App and Finder resolve the running account's home through `getpwuid_r`, using
matching, non-root real/effective user IDs. They append the fixed relative path
`Library/Application Support/SvnDock`. They do not use the build machine's
home, the `HOME` environment variable, a sandbox container home, or a
`SvnDockLocalSharedDirectory` plist value. The resolver does not create or read
application data during this lookup. Normal file/queue validation continues to
apply when that data is used.

The packaging contract is:

- Compile the App, Core, and Finder extension with
  `SVNDOCK_PORTABLE_SIGNED_BUILD`, without the local-build flag.
- Mark both signed Info plists with
  `SvnDockDistributionMode = portable-ad-hoc`; this identifies the package and
  is not a configurable directory or security grant.
- Do not write `SvnDockLocalSharedDirectory` into either plist.
- Sign the Finder extension with the existing
  `Packaging/LocalFinderExtension.entitlements`: App Sandbox plus the single
  home-relative read/write exception for
  `/Library/Application Support/SvnDock/`. Do not add broad home-directory
  access, App Groups, network access, or permission to execute SVN.
- Sign the main App without App Group entitlements, then verify the nested
  extension and complete App. The main App remains outside App Sandbox because
  it executes the recipient's SVN installation.

The existing current-account builder and its sealed absolute path are
unchanged. Normal Developer ID/App Group builds remain on their original
code path; a missing provisioned group never enables portable mode.

Finder support keeps the same limited local-data design as current-account
test builds. This directory is **not an App Group security boundary**: other
processes running as the same account can access it. It stores versioned
registry, status, and command-queue metadata, not SVN credentials. The main App
continues to validate queued requests independently. The portable mode does
not turn an ad-hoc signature into authenticated Apple Team identity.

Downloaded ad-hoc packages are not notarized and are not trusted by Gatekeeper
as identified-developer software. The App and Finder extension may require
user approval; automatic Finder activation is not promised. Users still need
SVN installed. Developer ID signing, notarization, and a provisioned App Group
remain the route for Apple-trusted distribution.

`PortableDirectoryRegressionChecks.swift` in the Core and Finder test targets
covers different account homes, invalid homes, root/identity mismatch rejection,
and a stale builder-specific plist path. Compile those checks with the portable
flag. They use synthetic account homes and a disposable bundle; they do not
modify account identities, user configuration, or production working copies.

Run the standalone Swift 6 checks on either native macOS architecture with
`bash Scripts/test-portable-shared-directory.sh`. The script also confirms that
combining portable and current-account compilation flags fails explicitly.
