# Local ad-hoc build

SvnDock can be assembled with Apple Command Line Tools when full Xcode and an
Apple signing identity are unavailable. The result is a structurally valid
macOS application containing a Finder Sync extension, with both bundles signed
ad-hoc and hardened runtime enabled.

This is a **current-user local test build**, not an Apple-trusted distribution
build. The ad-hoc signature itself is not bound to an account or Mac and does
not establish publisher identity. However, this build's sealed shared-data path
is account-specific, so rebuild it from the target macOS account instead of
copying one account's bundle to another:

- it has no Apple Team identity, provisioning profile, notarization ticket, or
  Developer ID signature;
- Gatekeeper on another Mac will not treat it as an identified-developer app;
- the provisioned App Group is unavailable to an ad-hoc signature;
- the embedded Finder extension therefore uses a narrowly scoped local
  Application Support directory instead of an App Group;
- no background Agent is embedded or registered.

The production code path is unchanged. The local directory is accepted only
when App and extension are compiled with `SVNDOCK_LOCAL_SIGNED_BUILD`, and the
absolute path is sealed into both Info plists before signing. The Finder
extension remains sandboxed and receives a temporary home-relative read/write
exception limited to `Library/Application Support/SvnDock`.

The local Application Support directory is not an App Group security boundary.
The main App is not sandboxed, and other processes running as the same account
can access it. It stores queue/status metadata rather than SVN credentials; do
not place credentials in that directory.

Prerequisites are macOS 14 or later, Command Line Tools with a Swift 6-capable
SDK, and SVN 1.14 available to the application at runtime. The arm64 path has
been tested on Apple Silicon; the script's x86_64 path has not been exercised
on physical Intel hardware. Run it as the signed-in desktop account, never via
`sudo` or as root. The output directory must be on a local device-backed
filesystem; network shares are rejected because the PID-based publication lock
cannot coordinate builders on different Macs.

## Build

From the repository root:

```sh
./Scripts/build-local-signed-app.sh /path/to/output
```

The script preserves an existing `SvnDock.app` or architecture-specific ZIP.
Pass `--force` only when you intentionally want to replace the same-name
outputs. An existing App is replaced only when its bundle identifier matches;
an existing same-name ZIP is replaced directly:

```sh
./Scripts/build-local-signed-app.sh --force /path/to/output
```

The script builds an optimized native binary for the current architecture,
links the Finder extension through `_NSExtensionMain`, materializes all build
settings in both Info plists, signs the nested extension before the containing
App, verifies both signatures, creates a ZIP archive, extracts it into a
temporary directory, and verifies the extracted App again. The printed SHA-256
is an integrity value, not proof of publisher identity.

Final App/ZIP replacement is serialized by a hidden publish lock. With
`--force`, both previous outputs are staged together and restored if a normal
error or handled termination occurs before final verification completes. A hard
kill can leave `.svndock-publish.lock`, `.svndock-publish-transaction`, and its
referenced `.svndock-output.*` recovery directory in the output folder. The
next build takes the lock and verifies or rolls back that recorded transaction
before doing new work. Recovery compares the expected App Code Directory hash
and ZIP SHA-256 as well as rechecking both signatures; inspect preserved files
instead of manually deleting an unrecognized recovery record. This covers
process crashes, not sudden power loss: the script does not issue filesystem
flush barriers and cannot promise crash consistency after hardware or power
failure.

## Install and enable

1. Disable any older SvnDock Finder extension and quit the older App.
2. Remove or archive other discoverable copies with the same bundle identifier,
   then move this `SvnDock.app` into `/Applications`. Keep one active copy.
3. Open `/Applications/SvnDock.app` once.
4. On macOS 15, open **System Settings → General → Login Items & Extensions →
   Extensions → Finder Extensions** and enable **SvnDock Finder**. On macOS 14,
   Finder extensions may instead appear under **Privacy & Security →
   Extensions**.
5. Register a disposable SVN working copy in SvnDock. Inside that root, Finder
   displays a **SvnDock** submenu. Verify a context-menu action and its badge
   before registering production working copies.

If Finder still holds an older extension instance, toggle the extension off and
on, then restart Finder after saving any active Finder work. Logging out and
back in is the final fallback. A quarantined copy can still be rejected by
Gatekeeper because ad-hoc signing provides no identified-developer trust;
prefer rebuilding from trusted source on the target account.

## Formal distribution requirements

A distributable build still requires full Xcode (recommended), unique App and
extension bundle identifiers owned by one Apple Developer Team, a registered
App Group attached to both identifiers, matching provisioning profiles, a
Developer ID Application identity with secure timestamp, Apple notarization,
and ticket stapling. The local builder must not be used as a substitute for
that release pipeline.
