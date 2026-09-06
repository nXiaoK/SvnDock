# Automatic DMG releases

The **Build and release DMGs** workflow runs on every push (branches and tags)
and can also be started with **Run workflow** once present on the default
branch. Deleted refs do not produce a build. New pushes do not cancel earlier
ones. Pull requests do not publish releases.

Two native macOS jobs build the same source commit:

| Download | Runner | Executable architecture |
| --- | --- | --- |
| `SvnDock-<version>-arm64.dmg` | `macos-15` | `arm64` |
| `SvnDock-<version>-x64.dmg` | `macos-15-intel` | `x86_64` |

Both jobs select Xcode 16.4 explicitly, verify the host architecture, ensure
`svn` and `svnadmin` are available, and run unit/integration tests, portable
directory checks, and Core smoke checks. Strict Swift 6 compilation builds the
App and Finder extension. The packager checks every bundled Mach-O's actual
architecture and rejects non-system runtime libraries.

After both DMGs pass, a separate job downloads them, creates `SHA256SUMS.txt`,
uploads all assets to a draft, and publishes that complete prerelease. Only
this final job receives `contents: write`; builds have read-only repository
access. The built-in `GITHUB_TOKEN` is used, so no personal access token needs
to be saved in repository secrets.

Each run/attempt creates an independent tag
`build-<run-number>-<attempt>-<short-commit>`, pointing to the exact source SHA.
Reruns do not replace older releases, and a slower earlier build cannot
overwrite a newer build's assets. Releases created with `GITHUB_TOKEN` do not
trigger another push workflow. All automatic builds are marked **prerelease**;
this workflow does not change an existing stable release or move its tag.

## Install

1. Open [GitHub Releases](https://github.com/nXiaoK/SvnDock/releases) and choose
   the latest completed build for the intended source commit.
2. Download `arm64.dmg` for Apple Silicon or `x64.dmg` for Intel.
3. Open the DMG and drag **SvnDock.app** onto **Applications**. The disk image
   contains a real link to `/Applications`, uses the standard Finder view,
   and does not run an installer or modify system settings.
4. Eject the disk image and open the App from Applications.
5. Install Subversion 1.14 separately if needed, for example with
   `brew install subversion`. SVN is not bundled inside the DMG.
6. To use Finder menus and badges, enable **SvnDock Finder** in System Settings
   after opening the installed App. Keep only one installed copy active.

These are **portable ad-hoc signed test builds**, without Developer ID or
Apple notarization. A successful signature check verifies package integrity;
it does not identify an Apple-trusted publisher. macOS may require explicit
user approval before opening downloaded software or enabling its extension.
The workflow does not bypass Gatekeeper. A trusted public distribution still
requires the project's Developer ID/App Group signing and notarization setup.

Unlike the current-account local builder, the release builder never embeds
the CI runner's home directory. App and Finder resolve the signed-in account's
fixed Application Support directory at runtime. See
[Portable ad-hoc distribution](Portable-Ad-Hoc-Build.md) for the boundaries.

## Reproduce a package locally

Run on macOS with a Swift 6-capable toolchain:

```sh
./Scripts/build-release-app.sh arm64 ./dist/portable-arm64
./Scripts/create-dmg.sh ./dist/portable-arm64/SvnDock.app ./dist/SvnDock-0.3.0-arm64.dmg

./Scripts/build-release-app.sh x64 ./dist/portable-x64
./Scripts/create-dmg.sh ./dist/portable-x64/SvnDock.app ./dist/SvnDock-0.3.0-x64.dmg
```

The App builder supports cross-compilation; the GitHub workflow uses native
jobs so tests execute on both CPU architectures. The deployment target is
macOS 14. The existing `build-local-signed-app.sh` keeps its account-specific
behavior and is not used to publish downloadable releases.

To validate installation contents and failure/overwrite handling:

```sh
./Scripts/test-portable-shared-directory.sh
./Scripts/test-create-dmg.sh ./dist/portable-arm64/SvnDock.app
```

DMG verification requires macOS disk-image services, including permission to
create and temporarily mount disk images. The test mounts read-only and
cleans up its own temporary volume. It does not launch or install the App.

## Troubleshooting a workflow

- If either architecture fails, no public release is created. Inspect that
  job's first failing step; successful DMGs remain in Actions artifacts for
  14 days.
- If upload or publication fails, a draft can remain for inspection. Re-run
  the workflow to create a new attempt without overwriting previous assets.
- A `403` during release creation usually means repository/organization policy
  disallows the workflow's requested write permission. Check **Settings →
  Actions → General → Workflow permissions** and the job log.
- If runner toolchains change, update the fixed `DEVELOPER_DIR` after checking
  availability on both runner images. Do not assume `macos-latest` means Intel.
- View the exact source commit in each release and in both bundles'
  `SvnDockSourceRevision` plist field. Version and build number come from
  `project.yml`.
