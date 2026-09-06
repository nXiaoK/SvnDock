#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: build-release-app.sh <arm64|x64> <output-directory>"
    echo "Build a portable, ad-hoc signed SvnDock.app for macOS 14+."
    echo "Existing App outputs are never overwritten. No installation is performed."
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then usage; exit 0; fi
if [[ $# -ne 2 ]]; then usage >&2; exit 2; fi
case "$1" in
    arm64) architecture=arm64 ;;
    x64|x86_64) architecture=x86_64 ;;
    *) echo "error: expected arm64 or x64" >&2; exit 2 ;;
esac
if [[ "$(uname -s)" != Darwin || "$EUID" -eq 0 ]]; then
    echo "error: run this builder on macOS as a regular user" >&2
    exit 1
fi
for tool in swift xcrun codesign plutil python3 ditto; do
    command -v "$tool" >/dev/null || { echo "error: missing $tool" >&2; exit 1; }
done

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source_directory="$(cd "$script_directory/.." && pwd -P)"
mkdir -p "$2"
output_directory="$(cd "$2" && pwd -P)"
final_app="$output_directory/SvnDock.app"
if [[ -e "$final_app" || -L "$final_app" ]]; then
    echo "error: output already exists: $final_app" >&2
    exit 1
fi
build_root="$(mktemp -d "${TMPDIR:-/tmp}/svndock-release-build.XXXXXX")"
output_stage=""
cleanup() {
    local status=$?
    trap - EXIT
    [[ -z "$output_stage" ]] || rm -rf "$output_stage"
    rm -rf "$build_root"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

export CLANG_MODULE_CACHE_PATH="$build_root/clang-cache"
export SWIFT_MODULECACHE_PATH="$build_root/swift-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_root/swiftpm-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULECACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

sdk="$(xcrun --sdk macosx --show-sdk-path)"
target="$architecture-apple-macosx14.0"
swift_options=(--disable-sandbox --package-path "$source_directory"
    --scratch-path "$build_root/swiftpm" --triple "$target" --sdk "$sdk" -c release)
echo "Building portable SvnDock for $architecture..."
swift build "${swift_options[@]}" --product SvnDock \
    -Xswiftc -swift-version -Xswiftc 6 \
    -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors \
    -Xswiftc -D -Xswiftc SVNDOCK_PORTABLE_SIGNED_BUILD
bin_directory="$(swift build "${swift_options[@]}" --show-bin-path)"

app="$build_root/SvnDock.app"
extension="$app/Contents/PlugIns/SvnDock Finder.appex"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$extension/Contents/MacOS"
cp "$bin_directory/SvnDock" "$app/Contents/MacOS/SvnDock"
xcrun swiftc -target "$target" -sdk "$sdk" -swift-version 6 \
    -strict-concurrency=complete -warnings-as-errors -O -whole-module-optimization \
    -D SVNDOCK_PORTABLE_SIGNED_BUILD -application-extension -parse-as-library \
    -module-name SvnDockFinderExtension -emit-executable \
    "$source_directory/FinderExtension/FinderBadgeImages.swift" \
    "$source_directory/FinderExtension/FinderCommandDispatcher.swift" \
    "$source_directory/FinderExtension/FinderMenuSelectionResolver.swift" \
    "$source_directory/FinderExtension/FinderSync.swift" \
    "$source_directory/FinderExtension/SharedContainer.swift" \
    "$source_directory/FinderExtension/SharedModels.swift" \
    -framework AppKit -framework FinderSync \
    -Xlinker -e -Xlinker _NSExtensionMain -Xlinker -no_adhoc_codesign \
    -o "$extension/Contents/MacOS/SvnDock Finder"

python3 - "$source_directory" "$app" <<'PY'
import pathlib
import plistlib
import re
import subprocess
import sys

source, app = map(pathlib.Path, sys.argv[1:])
settings = (source / 'project.yml').read_text()
def setting(name):
    match = re.search(r'^\s*' + re.escape(name) + r':\s*"?([^"\s]+)"?\s*$', settings, re.M)
    if not match:
        raise SystemExit(f'Missing project setting: {name}')
    return match[1]

bundle_id = setting('SVNDOCK_BUNDLE_ID_PREFIX') + '.app'
revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
if not re.fullmatch(r'[0-9a-f]{40}', revision):
    raise SystemExit('Invalid source revision')
for is_extension in (False, True):
    template = source / ('FinderExtension/Info.plist' if is_extension else 'SvnDockApp/Resources/Info.plist')
    destination = app / ('Contents/PlugIns/SvnDock Finder.appex/Contents/Info.plist' if is_extension else 'Contents/Info.plist')
    info = plistlib.loads(template.read_bytes())
    info.update({
        'CFBundleDevelopmentRegion': 'zh_CN',
        'CFBundleExecutable': 'SvnDock Finder' if is_extension else 'SvnDock',
        'CFBundleIdentifier': bundle_id + '.finder' if is_extension else bundle_id,
        'CFBundleName': 'SvnDock Finder' if is_extension else 'SvnDock',
        'CFBundleShortVersionString': setting('MARKETING_VERSION'),
        'CFBundleVersion': setting('CURRENT_PROJECT_VERSION'),
        'SvnDockAppGroupIdentifier': setting('SVNDOCK_APP_GROUP_IDENTIFIER'),
        'SvnDockDistributionMode': 'portable-ad-hoc',
        'SvnDockSourceRevision': revision,
    })
    info.pop('SvnDockLocalSharedDirectory', None)
    if is_extension:
        info['NSExtension']['NSExtensionPrincipalClass'] = 'SvnDockFinderExtension.FinderSync'
    else:
        info['CFBundleURLTypes'][0]['CFBundleURLName'] = bundle_id + '.finder-command'
    data = plistlib.dumps(info)
    if b'$(' in data:
        raise SystemExit('Unresolved build setting in Info.plist')
    destination.write_bytes(data)
PY
cp "$source_directory/SvnDockApp/Resources/SvnDock.icns" "$app/Contents/Resources/SvnDock.icns"
plutil -lint "$app/Contents/Info.plist" "$extension/Contents/Info.plist"

# Verify every Mach-O in the bundle before signing; a renamed Intel asset is
# not an Intel build. Reject accidental dependencies on the build machine.
python3 - "$app" "$architecture" <<'PY'
import pathlib
import subprocess
import sys

app, expected = pathlib.Path(sys.argv[1]), sys.argv[2]
executables = 0
for path in app.rglob('*'):
    if not path.is_file() or path.is_symlink():
        continue
    with path.open('rb') as stream:
        magic = stream.read(4)
    if magic not in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe'):
        continue
    actual = subprocess.check_output(['xcrun', 'lipo', '-archs', str(path)], text=True).strip()
    if actual != expected:
        raise SystemExit(f'Wrong architecture in {path.name}: {actual}, expected {expected}')
    libraries = subprocess.check_output(['xcrun', 'otool', '-L', str(path)], text=True)
    for line in libraries.splitlines()[1:]:
        library = line.strip().split(' (', 1)[0]
        if not library.startswith(('/System/Library/', '/usr/lib/')):
            raise SystemExit(f'Non-system runtime dependency in {path.name}: {library}')
    executables += 1
if executables != 2:
    raise SystemExit(f'Expected main App and Finder extension, found {executables} Mach-O files')
PY

codesign --force --sign - --timestamp=none --options runtime --generate-entitlement-der \
    --entitlements "$source_directory/Packaging/LocalFinderExtension.entitlements" "$extension"
codesign --force --sign - --timestamp=none --options runtime --generate-entitlement-der "$app"
codesign --verify --strict --verbose=2 "$extension"
codesign --verify --deep --strict --verbose=2 "$app"

output_stage="$(mktemp -d "$output_directory/.svndock-release.XXXXXX")"
ditto "$app" "$output_stage/SvnDock.app"
codesign --verify --deep --strict --verbose=2 "$output_stage/SvnDock.app"
mv -n "$output_stage/SvnDock.app" "$output_directory/"
if [[ -e "$output_stage/SvnDock.app" ]]; then
    echo "error: output appeared during the build; it was preserved" >&2
    exit 1
fi
echo "Portable app: $final_app"
echo "Architecture: $architecture; minimum macOS: 14.0"
echo "Ad-hoc signature only: no Developer ID identity or Apple notarization."
