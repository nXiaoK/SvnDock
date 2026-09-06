#!/bin/bash
# Integration checks against an already-built app; no GUI or network is used.
set -euo pipefail

if [[ $# -ne 1 || ! -d "$1" ]]; then
    echo "Usage: test-create-dmg.sh <signed-app-path>" >&2
    exit 2
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_PATH="$(cd "$1" && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/svndock-dmg-tests.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
MOUNT_POINT="$TEST_ROOT/mounted image"
MOUNTED=false
cleanup() {
    local result=$?
    trap - EXIT
    if [[ "$MOUNTED" == true ]]; then
        if ! hdiutil detach -quiet "$MOUNT_POINT"; then
            if ! hdiutil detach -quiet -force "$MOUNT_POINT"; then
                echo "error: could not detach test image; preserved $TEST_ROOT" >&2
                exit 1
            fi
        fi
    fi
    rm -rf "$TEST_ROOT"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
digest() { shasum -a 256 "$1" | awk '{ print $1 }'; }
expect_failure() {
    if "$@" >"$TEST_ROOT/expected-failure.log" 2>&1; then
        fail "command unexpectedly succeeded: $*"
    fi
}

EXECUTABLE="$(plutil -extract CFBundleExecutable raw "$APP_PATH/Contents/Info.plist")"
ARCHITECTURE="$(lipo -archs "$APP_PATH/Contents/MacOS/$EXECUTABLE")"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")"
case "$ARCHITECTURE" in
    arm64) ASSET_ARCH=arm64; WRONG_ARCH=x64 ;;
    x86_64) ASSET_ARCH=x64; WRONG_ARCH=arm64 ;;
    *) fail "test input must contain exactly one supported architecture" ;;
esac
SOURCE_HASH="$(digest "$APP_PATH/Contents/MacOS/$EXECUTABLE")"
SOURCE_SIGNATURE="$(codesign -d --verbose=4 "$APP_PATH" 2>&1 | awk -F= '/^CDHash=/ { print $2 }')"
[[ -n "$SOURCE_SIGNATURE" ]] || fail "input app has no code signature hash"
OUTPUT_DMG="$TEST_ROOT/SvnDock package-$ASSET_ARCH.dmg"

"$SCRIPT_DIR/create-dmg.sh" "$APP_PATH" "$OUTPUT_DMG"
hdiutil verify -quiet "$OUTPUT_DMG"
[[ "$(hdiutil imageinfo -format "$OUTPUT_DMG")" == "UDZO" ]] || fail "image is not compressed read-only UDZO"
mkdir "$MOUNT_POINT"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MOUNT_POINT" "$OUTPUT_DMG"
MOUNTED=true
diskutil info -plist "$MOUNT_POINT" > "$TEST_ROOT/volume-info.plist"
[[ "$(plutil -extract VolumeName raw "$TEST_ROOT/volume-info.plist")" == "SvnDock $VERSION ($ASSET_ARCH)" ]] \
    || fail "volume name does not identify the app version and architecture"
# Disk Utility's Writable value describes effective access across both the
# media and filesystem. The write attempt below checks the result as well.
WRITABLE="$(plutil -extract Writable raw "$TEST_ROOT/volume-info.plist")"
[[ "$WRITABLE" == false || "$WRITABLE" == 0 ]] || fail "image is reported as writable"
[[ -d "$MOUNT_POINT/SvnDock.app" ]] || fail "app is missing from volume root"
[[ -L "$MOUNT_POINT/Applications" ]] || fail "Applications is not a symbolic link"
[[ "$(readlink "$MOUNT_POINT/Applications")" == "/Applications" ]] || fail "Applications link points elsewhere"
codesign --verify --deep --strict "$MOUNT_POINT/SvnDock.app"
MOUNTED_SIGNATURE="$(codesign -d --verbose=4 "$MOUNT_POINT/SvnDock.app" 2>&1 | awk -F= '/^CDHash=/ { print $2 }')"
[[ "$MOUNTED_SIGNATURE" == "$SOURCE_SIGNATURE" ]] || fail "packaging changed the app signature"
[[ "$(lipo -archs "$MOUNT_POINT/SvnDock.app/Contents/MacOS/$EXECUTABLE")" == "$ARCHITECTURE" ]] \
    || fail "packaged architecture differs from source"
if touch "$MOUNT_POINT/write-must-fail" 2>/dev/null; then
    fail "mounted volume is writable"
fi
hdiutil detach -quiet "$MOUNT_POINT"
MOUNTED=false

IMAGE_HASH="$(digest "$OUTPUT_DMG")"
expect_failure "$SCRIPT_DIR/create-dmg.sh" "$APP_PATH" "$OUTPUT_DMG"
[[ "$(digest "$OUTPUT_DMG")" == "$IMAGE_HASH" ]] || fail "default invocation overwrote existing output"
expect_failure "$SCRIPT_DIR/create-dmg.sh" "$APP_PATH" "$TEST_ROOT/wrong-$WRONG_ARCH.dmg"
[[ ! -e "$TEST_ROOT/wrong-$WRONG_ARCH.dmg" ]] || fail "mislabeled image was published"
ln -s "$OUTPUT_DMG" "$TEST_ROOT/linked-$ASSET_ARCH.dmg"
expect_failure "$SCRIPT_DIR/create-dmg.sh" --force "$APP_PATH" "$TEST_ROOT/linked-$ASSET_ARCH.dmg"
[[ "$(readlink "$TEST_ROOT/linked-$ASSET_ARCH.dmg")" == "$OUTPUT_DMG" ]] || fail "force replaced an output symlink"

# Fail after staging the app to exercise cleanup and preservation of an
# existing image even when --force was explicitly requested.
mkdir "$TEST_ROOT/failing-tools"
cat > "$TEST_ROOT/failing-tools/hdiutil" <<'EOF'
#!/bin/bash
exit 73
EOF
chmod +x "$TEST_ROOT/failing-tools/hdiutil"
expect_failure env PATH="$TEST_ROOT/failing-tools:$PATH" \
    "$SCRIPT_DIR/create-dmg.sh" --force "$APP_PATH" "$OUTPUT_DMG"
[[ "$(digest "$OUTPUT_DMG")" == "$IMAGE_HASH" ]] || fail "failed packaging replaced existing output"
shopt -s nullglob
STAGES=("$TEST_ROOT"/.svndock-dmg.*)
[[ ${#STAGES[@]} -eq 0 ]] || fail "failed packaging left temporary files"

"$SCRIPT_DIR/create-dmg.sh" --force "$APP_PATH" "$OUTPUT_DMG"
hdiutil verify -quiet "$OUTPUT_DMG"
[[ "$(digest "$APP_PATH/Contents/MacOS/$EXECUTABLE")" == "$SOURCE_HASH" ]] || fail "input executable was modified"
codesign --verify --deep --strict "$APP_PATH"
echo "Passed DMG content, signature, architecture, read-only, overwrite, failure cleanup and force checks ($ARCHITECTURE)"
