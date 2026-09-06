#!/bin/bash
# Package an existing signed app without launching Finder or changing its signature.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: create-dmg.sh [--force] <app-path> <output-dmg-path>

Create a compressed, read-only macOS disk image containing SvnDock.app and an
Applications link. The output directory must exist. Name the image with an
-arm64.dmg or -x64.dmg suffix matching the app's actual architecture.
Existing outputs are preserved unless --force is supplied.

The image uses the standard Finder presentation; no custom icon layout is set.
EOF
}

fail() { echo "error: $*" >&2; exit 1; }

FORCE=false
if [[ "${1:-}" == "--force" ]]; then
    FORCE=true
    shift
fi
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
if [[ $# -ne 2 || "$1" == -* || "$2" == -* ]]; then
    usage >&2
    exit 2
fi
[[ "$(uname -s)" == "Darwin" ]] || fail "disk image packaging requires macOS"
for tool in codesign ditto hdiutil lipo plutil mktemp ln link mv; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool is missing: $tool"
done

[[ -d "$1" ]] || fail "app bundle does not exist: $1"
APP_PATH="$(cd "$1" && pwd -P)"
[[ "$APP_PATH" == *.app && -f "$APP_PATH/Contents/Info.plist" ]] \
    || fail "input must be a macOS .app bundle"
OUTPUT_PARENT="$(dirname "$2")"
[[ -d "$OUTPUT_PARENT" ]] || fail "output directory does not exist: $OUTPUT_PARENT"
OUTPUT_DIR="$(cd "$OUTPUT_PARENT" && pwd -P)"
case "$OUTPUT_DIR/" in
    "$APP_PATH/"*) fail "output must be outside the input app bundle" ;;
esac
OUTPUT_NAME="$(basename "$2")"
OUTPUT_DMG="$OUTPUT_DIR/$OUTPUT_NAME"
[[ "$OUTPUT_NAME" == *.dmg ]] || fail "output path must end in .dmg"
[[ ! -d "$OUTPUT_DMG" ]] || fail "output path is a directory: $OUTPUT_DMG"
if [[ -e "$OUTPUT_DMG" || -L "$OUTPUT_DMG" ]]; then
    [[ "$FORCE" == true ]] || fail "output already exists; use --force to replace it: $OUTPUT_DMG"
    [[ -f "$OUTPUT_DMG" && ! -L "$OUTPUT_DMG" ]] \
        || fail "--force only replaces a regular disk image file"
fi

EXECUTABLE="$(plutil -extract CFBundleExecutable raw "$APP_PATH/Contents/Info.plist")"
case "$EXECUTABLE" in
    ""|.|..|*/*) fail "app has an invalid CFBundleExecutable" ;;
esac
APP_BINARY="$APP_PATH/Contents/MacOS/$EXECUTABLE"
[[ -f "$APP_BINARY" && -x "$APP_BINARY" ]] || fail "app executable is missing: $APP_BINARY"
ARCHITECTURE="$(lipo -archs "$APP_BINARY")"
case "$ARCHITECTURE" in
    arm64) ASSET_ARCH=arm64 ;;
    x86_64) ASSET_ARCH=x64 ;;
    *) fail "expected a single arm64 or x86_64 app, found: $ARCHITECTURE" ;;
esac
[[ "$OUTPUT_NAME" == *-"$ASSET_ARCH".dmg ]] \
    || fail "this $ARCHITECTURE app requires an output name ending in -$ASSET_ARCH.dmg"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")"
case "$VERSION" in
    ""|*[!0-9A-Za-z.+_-]*) fail "app version is missing or unsuitable for a volume name" ;;
esac
[[ ${#VERSION} -le 64 ]] || fail "app version is too long for a volume name"

# Verify first, then copy without resigning. A failed package never changes the
# source bundle or a previously published image.
codesign --verify --deep --strict "$APP_PATH"
PACKAGE_STAGE="$(mktemp -d "$OUTPUT_DIR/.svndock-dmg.XXXXXX")"
cleanup() {
    local result=$?
    trap - EXIT
    rm -rf "$PACKAGE_STAGE"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$PACKAGE_STAGE/content"
ditto "$APP_PATH" "$PACKAGE_STAGE/content/SvnDock.app"
ln -s /Applications "$PACKAGE_STAGE/content/Applications"
codesign --verify --deep --strict "$PACKAGE_STAGE/content/SvnDock.app"

# hdiutil manages image creation internally; this script does not attach a
# volume, so it needs no GUI session and leaves no mount for a caller to eject.
STAGED_DMG="$PACKAGE_STAGE/package.dmg"
hdiutil create -fs HFS+ -format UDZO \
    -volname "SvnDock $VERSION ($ASSET_ARCH)" \
    -srcfolder "$PACKAGE_STAGE/content" "$STAGED_DMG" \
    || fail "disk image creation failed"
hdiutil verify "$STAGED_DMG" || fail "disk image verification failed"
[[ "$(hdiutil imageinfo -format "$STAGED_DMG")" == "UDZO" ]] \
    || fail "created image is not in the expected compressed, read-only format"

if [[ "$FORCE" == true ]]; then
    # The stage is on the same filesystem, so replacement is a single rename.
    [[ ! -d "$OUTPUT_DMG" && ! -L "$OUTPUT_DMG" ]] || fail "output changed during packaging"
    mv -f "$STAGED_DMG" "$OUTPUT_DMG"
else
    # A hard link publishes exclusively, including when another process races
    # this invocation. Never use a check followed by an overwriting rename.
    link "$STAGED_DMG" "$OUTPUT_DMG" || fail "could not publish image without replacing an existing output"
fi
echo "Created $OUTPUT_DMG ($ARCHITECTURE; volume: SvnDock $VERSION ($ASSET_ARCH))"
