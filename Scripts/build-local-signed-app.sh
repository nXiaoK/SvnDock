#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: build-local-signed-app.sh [--force] [output-directory]

Build a current-account, ad-hoc signed SvnDock.app. Existing SvnDock.app or
architecture-specific ZIP outputs are preserved unless --force is supplied.
EOF
}

FORCE=false
OUTPUT_ARGUMENT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            FORCE=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -* )
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [[ -n "$OUTPUT_ARGUMENT" ]]; then
                echo "error: only one output directory may be supplied" >&2
                usage >&2
                exit 2
            fi
            OUTPUT_ARGUMENT="$1"
            ;;
    esac
    shift
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: this builder requires macOS" >&2
    exit 1
fi
if [[ "$EUID" -eq 0 ]]; then
    echo "error: do not run this current-account builder as root or through sudo" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
OUTPUT_DIR="${OUTPUT_ARGUMENT:-$ROOT_DIR/dist}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"

for tool in swift xcrun codesign plutil zip unzip shasum awk grep id shlock readlink ln df stat; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: required tool is missing: $tool" >&2
        exit 1
    fi
done

OUTPUT_FILESYSTEM_SOURCE="$(df -P "$OUTPUT_DIR" | awk 'END { print $1 }')"
case "$OUTPUT_FILESYSTEM_SOURCE" in
    /dev/*) ;;
    *)
        echo "error: output must be on a local device-backed filesystem, not: $OUTPUT_FILESYSTEM_SOURCE" >&2
        exit 1
        ;;
esac

CURRENT_USER="$(id -un)"
CURRENT_UID="$(id -u)"
ACCOUNT_HOME="$(id -P "$CURRENT_USER" | awk -F ':' '{ print $9; exit }')"
if [[ -z "$ACCOUNT_HOME" || ! -d "$ACCOUNT_HOME" ]]; then
    echo "error: unable to resolve the current account's home directory" >&2
    exit 1
fi
ACCOUNT_HOME="$(cd "$ACCOUNT_HOME" && pwd -P)"
ENVIRONMENT_HOME="$(cd "${HOME:?HOME is not set}" 2>/dev/null && pwd -P)" || {
    echo "error: HOME does not identify an accessible directory" >&2
    exit 1
}
if [[ "$ENVIRONMENT_HOME" != "$ACCOUNT_HOME" ]]; then
    echo "error: HOME does not match the current account's directory: $ACCOUNT_HOME" >&2
    exit 1
fi

ARCH="$(uname -m)"
case "$ARCH" in
    arm64|x86_64) ;;
    *)
        echo "error: unsupported build architecture: $ARCH" >&2
        exit 1
        ;;
esac

VERSION="$(awk -F '"' '/MARKETING_VERSION:/ { print $2; exit }' "$ROOT_DIR/project.yml")"
BUILD_NUMBER="$(awk -F '"' '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$ROOT_DIR/project.yml")"
BUNDLE_PREFIX="$(awk '/SVNDOCK_BUNDLE_ID_PREFIX:/ { print $2; exit }' "$ROOT_DIR/project.yml")"
APP_GROUP="$(awk '/SVNDOCK_APP_GROUP_IDENTIFIER:/ { print $2; exit }' "$ROOT_DIR/project.yml")"

if [[ -z "$VERSION" || -z "$BUILD_NUMBER" || -z "$BUNDLE_PREFIX" || -z "$APP_GROUP" ]]; then
    echo "error: unable to read version or identifier settings from project.yml" >&2
    exit 1
fi

APP_BUNDLE_ID="$BUNDLE_PREFIX.app"
EXTENSION_BUNDLE_ID="$APP_BUNDLE_ID.finder"
LOCAL_SHARED_DIRECTORY="$ACCOUNT_HOME/Library/Application Support/SvnDock"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="$ARCH-apple-macosx14.0"
FINAL_APP="$OUTPUT_DIR/SvnDock.app"
FINAL_ZIP="$OUTPUT_DIR/SvnDock-local-$ARCH.zip"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/svndock-local-build.XXXXXX")"
OUTPUT_STAGE=""
STAGED_OUTPUT_APP=""
STAGED_OUTPUT_ZIP=""
PUBLISH_LOCK="$OUTPUT_DIR/.svndock-publish.lock"
TRANSACTION_LINK="$OUTPUT_DIR/.svndock-publish-transaction"
TRANSACTION_INTENDED=false

path_exists() {
    [[ -n "${1:-}" && ( -e "$1" || -L "$1" ) ]]
}

bundle_cdhash() {
    codesign -d --verbose=4 "$1" 2>&1 \
        | awk -F '=' '/^CDHash=/ { print $2; exit }'
}

archive_sha256() {
    shasum -a 256 "$1" | awk '{ print $1; exit }'
}

read_digest_file() {
    local digest_file="$1"
    local digest=""
    if [[ ! -f "$digest_file" || -L "$digest_file" ]]; then
        return 1
    fi
    IFS= read -r digest < "$digest_file" || true
    case "$digest" in
        ""|*[!0-9a-fA-F]*) return 1 ;;
        *) printf '%s' "$digest" ;;
    esac
}

publish_lock_owner() {
    local owner=""
    if [[ -f "$PUBLISH_LOCK" && ! -L "$PUBLISH_LOCK" ]]; then
        IFS= read -r owner < "$PUBLISH_LOCK" || true
    fi
    printf '%s' "$owner"
}

owns_publish_lock() {
    [[ "$(publish_lock_owner)" == "$$" ]]
}

acquire_publish_lock() {
    local owner=""
    if shlock -f "$PUBLISH_LOCK" -p "$$"; then
        return 0
    fi
    owner="$(publish_lock_owner)"
    echo "error: another SvnDock build is publishing to $OUTPUT_DIR" >&2
    [[ -n "$owner" ]] && echo "  lock owner PID: $owner" >&2
    echo "  lock: $PUBLISH_LOCK" >&2
    return 1
}

release_publish_lock() {
    if owns_publish_lock; then
        rm -f "$PUBLISH_LOCK"
    fi
}

transaction_link_target() {
    if [[ -L "$TRANSACTION_LINK" ]]; then
        readlink "$TRANSACTION_LINK"
        return 0
    fi
    return 1
}

validate_transaction_stage() {
    local stage="$1"
    local suffix=""
    local stage_owner=""
    local stage_mode=""
    case "$stage" in
        "$OUTPUT_DIR"/.svndock-output.*) ;;
        *) return 1 ;;
    esac
    suffix="${stage#"$OUTPUT_DIR"/.svndock-output.}"
    [[ -n "$suffix" && "$suffix" != */* && -d "$stage" && ! -L "$stage" ]] || return 1
    stage_owner="$(stat -f '%u' "$stage")" || return 1
    stage_mode="$(stat -f '%Lp' "$stage")" || return 1
    [[ "$stage_owner" == "$CURRENT_UID" && "$stage_mode" == "700" ]]
}

read_transaction_architecture() {
    local stage="$1"
    local transaction_arch=""
    local architecture_file="$stage/publish-architecture"
    if [[ ! -f "$architecture_file" || -L "$architecture_file" ]]; then
        return 1
    fi
    IFS= read -r transaction_arch < "$architecture_file" || true
    case "$transaction_arch" in
        arm64|x86_64)
            printf '%s' "$transaction_arch"
            ;;
        *)
            return 1
            ;;
    esac
}

rollback_artifact() {
    local final_path="$1"
    local staged_path="$2"
    local previous_path="$3"
    local failed_path="$4"
    local label="$5"

    if path_exists "$previous_path"; then
        if path_exists "$final_path"; then
            if path_exists "$failed_path"; then
                echo "error: cannot roll back $label because final and failed-new paths both exist" >&2
                return 1
            fi
            if ! mv "$final_path" "$failed_path"; then
                echo "error: unable to move the new $label aside during rollback" >&2
                return 1
            fi
        fi
        if path_exists "$final_path"; then
            echo "error: refusing to restore the previous $label over an occupied final path" >&2
            return 1
        fi
        if ! mv "$previous_path" "$final_path"; then
            echo "error: unable to restore the previous $label" >&2
            return 1
        fi
    elif path_exists "$failed_path"; then
        # A prior recovery attempt already moved the new artifact aside and,
        # when applicable, restored the previous artifact.
        return 0
    elif ! path_exists "$staged_path" && path_exists "$final_path"; then
        if ! mv "$final_path" "$failed_path"; then
            echo "error: unable to remove the partially published $label" >&2
            return 1
        fi
    fi
}

rollback_transaction_contents() {
    local stage="$1"
    local transaction_arch="$2"
    local rollback_failed=false
    local transaction_final_zip="$OUTPUT_DIR/SvnDock-local-$transaction_arch.zip"

    if ! validate_transaction_stage "$stage"; then
        echo "error: refusing to roll back an invalid transaction stage: $stage" >&2
        return 1
    fi
    rollback_artifact \
        "$FINAL_APP" \
        "$stage/SvnDock.app" \
        "$stage/previous-SvnDock.app" \
        "$stage/failed-new-SvnDock.app" \
        "App" || rollback_failed=true
    rollback_artifact \
        "$transaction_final_zip" \
        "$stage/SvnDock-local-$transaction_arch.zip" \
        "$stage/previous-SvnDock-local-$transaction_arch.zip" \
        "$stage/failed-new-SvnDock-local-$transaction_arch.zip" \
        "ZIP" || rollback_failed=true

    [[ "$rollback_failed" == false ]]
}

remove_transaction_record() {
    local stage="$1"
    local target=""
    if ! validate_transaction_stage "$stage"; then
        echo "error: refusing to remove an invalid transaction stage: $stage" >&2
        return 1
    fi
    if [[ -L "$TRANSACTION_LINK" ]]; then
        target="$(readlink "$TRANSACTION_LINK")"
        if [[ "$target" != "$stage" ]]; then
            echo "error: refusing to remove a transaction record owned by another stage" >&2
            return 1
        fi
        rm -f "$TRANSACTION_LINK" || return 1
    elif [[ -e "$TRANSACTION_LINK" ]]; then
        echo "error: transaction record is not a symbolic link: $TRANSACTION_LINK" >&2
        return 1
    fi
    rm -rf "$stage"
}

verify_recovered_commit() {
    local stage="$1"
    local transaction_arch="$2"
    local transaction_final_zip="$OUTPUT_DIR/SvnDock-local-$transaction_arch.zip"
    local verify_root="$BUILD_ROOT/recovered-zip-verify"
    local existing_bundle_id=""
    local expected_app_cdhash=""
    local expected_zip_sha256=""
    local final_app_cdhash=""
    local extracted_app_cdhash=""
    local final_zip_sha256=""

    if ! path_exists "$FINAL_APP" || ! path_exists "$transaction_final_zip"; then
        return 1
    fi
    expected_app_cdhash="$(read_digest_file "$stage/publish-app-cdhash")" || return 1
    expected_zip_sha256="$(read_digest_file "$stage/publish-zip-sha256")" || return 1
    existing_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$FINAL_APP/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$existing_bundle_id" == "$APP_BUNDLE_ID" ]] || return 1
    codesign --verify --deep --strict --verbose=2 "$FINAL_APP" || return 1
    unzip -tq "$transaction_final_zip" || return 1
    final_app_cdhash="$(bundle_cdhash "$FINAL_APP")" || return 1
    final_zip_sha256="$(archive_sha256 "$transaction_final_zip")" || return 1
    [[ "$final_app_cdhash" == "$expected_app_cdhash" ]] || return 1
    [[ "$final_zip_sha256" == "$expected_zip_sha256" ]] || return 1
    rm -rf "$verify_root"
    mkdir -p "$verify_root"
    unzip -q "$transaction_final_zip" -d "$verify_root" || return 1
    codesign --verify --deep --strict --verbose=2 "$verify_root/SvnDock.app" || return 1
    extracted_app_cdhash="$(bundle_cdhash "$verify_root/SvnDock.app")" || return 1
    [[ "$extracted_app_cdhash" == "$expected_app_cdhash" ]]
}

recover_orphaned_transaction() {
    local stage=""
    local transaction_arch=""
    local committed=false

    if ! path_exists "$TRANSACTION_LINK"; then
        return 0
    fi
    if ! owns_publish_lock; then
        echo "error: internal error: transaction recovery requires the publish lock" >&2
        return 1
    fi
    if [[ ! -L "$TRANSACTION_LINK" ]]; then
        echo "error: refusing to use an invalid transaction record: $TRANSACTION_LINK" >&2
        return 1
    fi
    stage="$(transaction_link_target)"
    if ! validate_transaction_stage "$stage"; then
        echo "error: transaction record points outside a valid SvnDock stage: $stage" >&2
        return 1
    fi
    transaction_arch="$(read_transaction_architecture "$stage")" || {
        echo "error: transaction stage has invalid architecture metadata: $stage" >&2
        return 1
    }

    if [[ -f "$stage/publish-committed" && ! -L "$stage/publish-committed" ]]; then
        if verify_recovered_commit "$stage" "$transaction_arch"; then
            committed=true
            echo "Recovered a completed SvnDock publication."
        else
            echo "warning: a committed publication failed verification; rolling it back" >&2
        fi
    fi
    if [[ "$committed" == false ]]; then
        echo "Recovering an interrupted SvnDock publication..."
        if ! rollback_transaction_contents "$stage" "$transaction_arch"; then
            echo "error: automatic recovery was incomplete; recovery files remain at $stage" >&2
            return 1
        fi
    fi
    remove_transaction_record "$stage"
}

cleanup() {
    local exit_status=$?
    local rollback_failed=false
    local cleanup_failed=false
    local transaction_target=""
    local transaction_arch=""

    trap '' HUP INT TERM
    set +e
    if [[ -n "$OUTPUT_STAGE" && -L "$TRANSACTION_LINK" ]]; then
        transaction_target="$(readlink "$TRANSACTION_LINK")"
    fi
    if [[ -n "$OUTPUT_STAGE" && "$transaction_target" == "$OUTPUT_STAGE" ]]; then
        transaction_arch="$(read_transaction_architecture "$OUTPUT_STAGE")" || rollback_failed=true
        if [[ "$rollback_failed" == false
              && ( ! -f "$OUTPUT_STAGE/publish-committed" || -L "$OUTPUT_STAGE/publish-committed" ) ]]; then
            rollback_transaction_contents "$OUTPUT_STAGE" "$transaction_arch" || rollback_failed=true
        fi
        if [[ "$rollback_failed" == false ]]; then
            remove_transaction_record "$OUTPUT_STAGE" || cleanup_failed=true
        fi
    elif [[ -n "$OUTPUT_STAGE" && -d "$OUTPUT_STAGE" && "$TRANSACTION_INTENDED" == false ]]; then
        rm -rf "$OUTPUT_STAGE" || cleanup_failed=true
    elif [[ -n "$OUTPUT_STAGE" && -d "$OUTPUT_STAGE" ]]; then
        echo "error: preserving unrecognized publication state at $OUTPUT_STAGE" >&2
        cleanup_failed=true
    fi

    rm -rf "$BUILD_ROOT" || cleanup_failed=true
    release_publish_lock || cleanup_failed=true

    if [[ "$rollback_failed" == true ]]; then
        echo "error: automatic rollback was incomplete; recovery files remain at $OUTPUT_STAGE" >&2
        [[ "$exit_status" -eq 0 ]] && exit_status=1
    fi
    if [[ "$cleanup_failed" == true ]]; then
        echo "error: unable to remove all temporary publication state" >&2
        [[ "$exit_status" -eq 0 ]] && exit_status=1
    fi
    trap - EXIT
    exit "$exit_status"
}

handle_signal() {
    local signal_number="$1"
    trap '' HUP INT TERM
    exit "$((128 + signal_number))"
}

trap cleanup EXIT
trap 'handle_signal 1' HUP
trap 'handle_signal 2' INT
trap 'handle_signal 15' TERM

acquire_publish_lock
recover_orphaned_transaction

if [[ "$FORCE" == false && ( -e "$FINAL_APP" || -L "$FINAL_APP" || -e "$FINAL_ZIP" || -L "$FINAL_ZIP" ) ]]; then
    echo "error: output already exists; preserve it or rerun with --force:" >&2
    [[ -e "$FINAL_APP" || -L "$FINAL_APP" ]] && echo "  $FINAL_APP" >&2
    [[ -e "$FINAL_ZIP" || -L "$FINAL_ZIP" ]] && echo "  $FINAL_ZIP" >&2
    exit 1
fi

release_publish_lock

export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$BUILD_ROOT/swift-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/swiftpm-module-cache"
mkdir -p \
    "$CLANG_MODULE_CACHE_PATH" \
    "$SWIFT_MODULECACHE_PATH" \
    "$SWIFTPM_MODULECACHE_OVERRIDE"

SWIFTPM_SCRATCH="$BUILD_ROOT/swiftpm"
APP_STAGE="$BUILD_ROOT/stage/SvnDock.app"
APP_EXECUTABLE="$APP_STAGE/Contents/MacOS/SvnDock"
APPEX_STAGE="$APP_STAGE/Contents/PlugIns/SvnDock Finder.appex"
APPEX_EXECUTABLE="$APPEX_STAGE/Contents/MacOS/SvnDock Finder"

mkdir -p \
    "$APP_STAGE/Contents/MacOS" \
    "$APP_STAGE/Contents/Resources" \
    "$APPEX_STAGE/Contents/MacOS"

echo "Building SvnDock $VERSION ($BUILD_NUMBER) for $ARCH..."
swift build \
    --disable-sandbox \
    --package-path "$ROOT_DIR" \
    --scratch-path "$SWIFTPM_SCRATCH" \
    -c release \
    --product SvnDock \
    -Xswiftc -swift-version \
    -Xswiftc 6 \
    -Xswiftc -strict-concurrency=complete \
    -Xswiftc -warnings-as-errors \
    -Xswiftc -D \
    -Xswiftc SVNDOCK_LOCAL_SIGNED_BUILD

SWIFTPM_BIN_DIRECTORY="$(swift build \
    --disable-sandbox \
    --package-path "$ROOT_DIR" \
    --scratch-path "$SWIFTPM_SCRATCH" \
    -c release \
    --show-bin-path)"
cp "$SWIFTPM_BIN_DIRECTORY/SvnDock" "$APP_EXECUTABLE"

echo "Building Finder Sync extension..."
xcrun swiftc \
    -target "$TARGET" \
    -sdk "$SDK_PATH" \
    -swift-version 6 \
    -strict-concurrency=complete \
    -warnings-as-errors \
    -O \
    -whole-module-optimization \
    -D SVNDOCK_LOCAL_SIGNED_BUILD \
    -application-extension \
    -parse-as-library \
    -module-name SvnDockFinderExtension \
    -emit-executable \
    "$ROOT_DIR/FinderExtension/FinderBadgeImages.swift" \
    "$ROOT_DIR/FinderExtension/FinderCommandDispatcher.swift" \
    "$ROOT_DIR/FinderExtension/FinderMenuSelectionResolver.swift" \
    "$ROOT_DIR/FinderExtension/FinderSync.swift" \
    "$ROOT_DIR/FinderExtension/SharedContainer.swift" \
    "$ROOT_DIR/FinderExtension/SharedModels.swift" \
    -framework AppKit \
    -framework FinderSync \
    -Xlinker -e \
    -Xlinker _NSExtensionMain \
    -Xlinker -no_adhoc_codesign \
    -o "$APPEX_EXECUTABLE"

cp "$ROOT_DIR/SvnDockApp/Resources/Info.plist" "$APP_STAGE/Contents/Info.plist"
cp "$ROOT_DIR/SvnDockApp/Resources/SvnDock.icns" "$APP_STAGE/Contents/Resources/SvnDock.icns"
plutil -replace CFBundleExecutable -string "SvnDock" "$APP_STAGE/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$APP_BUNDLE_ID" "$APP_STAGE/Contents/Info.plist"
plutil -replace CFBundleName -string "SvnDock" "$APP_STAGE/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP_STAGE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP_STAGE/Contents/Info.plist"
plutil -replace CFBundleURLTypes.0.CFBundleURLName -string "$APP_BUNDLE_ID.finder-command" "$APP_STAGE/Contents/Info.plist"
plutil -replace SvnDockAppGroupIdentifier -string "$APP_GROUP" "$APP_STAGE/Contents/Info.plist"
plutil -insert SvnDockLocalSharedDirectory -string "$LOCAL_SHARED_DIRECTORY" "$APP_STAGE/Contents/Info.plist"

cp "$ROOT_DIR/FinderExtension/Info.plist" "$APPEX_STAGE/Contents/Info.plist"
plutil -replace CFBundleDevelopmentRegion -string "zh_CN" "$APPEX_STAGE/Contents/Info.plist"
plutil -replace CFBundleExecutable -string "SvnDock Finder" "$APPEX_STAGE/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$EXTENSION_BUNDLE_ID" "$APPEX_STAGE/Contents/Info.plist"
plutil -replace CFBundleName -string "SvnDock Finder" "$APPEX_STAGE/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APPEX_STAGE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APPEX_STAGE/Contents/Info.plist"
plutil -replace NSExtension.NSExtensionPrincipalClass -string "SvnDockFinderExtension.FinderSync" "$APPEX_STAGE/Contents/Info.plist"
plutil -replace SvnDockAppGroupIdentifier -string "$APP_GROUP" "$APPEX_STAGE/Contents/Info.plist"
plutil -insert SvnDockLocalSharedDirectory -string "$LOCAL_SHARED_DIRECTORY" "$APPEX_STAGE/Contents/Info.plist"

plutil -lint "$APP_STAGE/Contents/Info.plist" "$APPEX_STAGE/Contents/Info.plist"
if grep -R -F '$(' "$APP_STAGE/Contents/Info.plist" "$APPEX_STAGE/Contents/Info.plist" >/dev/null; then
    echo "error: unresolved build setting remains in a staged Info.plist" >&2
    exit 1
fi

echo "Applying local ad-hoc signatures..."
codesign \
    --force \
    --sign - \
    --timestamp=none \
    --options runtime \
    --generate-entitlement-der \
    --entitlements "$ROOT_DIR/Packaging/LocalFinderExtension.entitlements" \
    "$APPEX_STAGE"
codesign \
    --force \
    --sign - \
    --timestamp=none \
    --options runtime \
    --generate-entitlement-der \
    "$APP_STAGE"

codesign --verify --strict --verbose=2 "$APPEX_STAGE"
codesign --verify --deep --strict --verbose=2 "$APP_STAGE"

OUTPUT_STAGE="$(mktemp -d "$OUTPUT_DIR/.svndock-output.XXXXXX")"
chmod 700 "$OUTPUT_STAGE"
STAGED_OUTPUT_APP="$OUTPUT_STAGE/SvnDock.app"
STAGED_OUTPUT_ZIP="$OUTPUT_STAGE/SvnDock-local-$ARCH.zip"
printf '%s\n' "$ARCH" > "$OUTPUT_STAGE/publish-architecture"
/usr/bin/ditto "$APP_STAGE" "$STAGED_OUTPUT_APP"
codesign --verify --deep --strict --verbose=2 "$STAGED_OUTPUT_APP"

(
    cd "$OUTPUT_STAGE"
    COPYFILE_DISABLE=1 zip -X -q -r "$STAGED_OUTPUT_ZIP" "SvnDock.app"
)
unzip -tq "$STAGED_OUTPUT_ZIP"
ZIP_VERIFY_ROOT="$BUILD_ROOT/zip-verify"
mkdir -p "$ZIP_VERIFY_ROOT"
unzip -q "$STAGED_OUTPUT_ZIP" -d "$ZIP_VERIFY_ROOT"
codesign --verify --deep --strict --verbose=2 "$ZIP_VERIFY_ROOT/SvnDock.app"
EXPECTED_APP_CDHASH="$(bundle_cdhash "$STAGED_OUTPUT_APP")"
EXPECTED_ZIP_SHA256="$(archive_sha256 "$STAGED_OUTPUT_ZIP")"
if [[ -z "$EXPECTED_APP_CDHASH" || -z "$EXPECTED_ZIP_SHA256" ]]; then
    echo "error: unable to calculate publication digests" >&2
    exit 1
fi
printf '%s\n' "$EXPECTED_APP_CDHASH" > "$OUTPUT_STAGE/publish-app-cdhash"
printf '%s\n' "$EXPECTED_ZIP_SHA256" > "$OUTPUT_STAGE/publish-zip-sha256"

acquire_publish_lock
recover_orphaned_transaction
if [[ "$FORCE" == false && ( -e "$FINAL_APP" || -L "$FINAL_APP" || -e "$FINAL_ZIP" || -L "$FINAL_ZIP" ) ]]; then
    echo "error: an output appeared while the build was running; refusing to replace it" >&2
    exit 1
fi

PREVIOUS_APP="$OUTPUT_STAGE/previous-SvnDock.app"
PREVIOUS_ZIP="$OUTPUT_STAGE/previous-SvnDock-local-$ARCH.zip"
if [[ -e "$FINAL_APP" || -L "$FINAL_APP" ]]; then
    EXISTING_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$FINAL_APP/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$EXISTING_BUNDLE_ID" != "$APP_BUNDLE_ID" ]]; then
        echo "error: refusing to replace $FINAL_APP because its bundle identifier is not $APP_BUNDLE_ID" >&2
        exit 1
    fi
fi

if ! ln -s "$OUTPUT_STAGE" "$TRANSACTION_LINK"; then
    echo "error: unable to create the durable publication record: $TRANSACTION_LINK" >&2
    exit 1
fi
TRANSACTION_INTENDED=true

if [[ -e "$FINAL_APP" || -L "$FINAL_APP" ]]; then
    mv "$FINAL_APP" "$PREVIOUS_APP"
fi
if [[ -e "$FINAL_ZIP" || -L "$FINAL_ZIP" ]]; then
    mv "$FINAL_ZIP" "$PREVIOUS_ZIP"
fi

if ! mv "$STAGED_OUTPUT_APP" "$FINAL_APP"; then
    echo "error: unable to install the newly verified app into the output directory" >&2
    exit 1
fi
if ! mv "$STAGED_OUTPUT_ZIP" "$FINAL_ZIP"; then
    echo "error: unable to install the newly verified archive into the output directory" >&2
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "$FINAL_APP"
unzip -tq "$FINAL_ZIP"
[[ "$(bundle_cdhash "$FINAL_APP")" == "$EXPECTED_APP_CDHASH" ]]
[[ "$(archive_sha256 "$FINAL_ZIP")" == "$EXPECTED_ZIP_SHA256" ]]
: > "$OUTPUT_STAGE/publish-committed"

echo
echo "Local signed app: $FINAL_APP"
echo "Archive:          $FINAL_ZIP"
echo "Shared data:      $LOCAL_SHARED_DIRECTORY"
shasum -a 256 "$FINAL_ZIP"
echo
echo "Signature scope: ad-hoc; no publisher identity, Gatekeeper trust, or Apple notarization."
echo "Configuration:   shared-data path is sealed for account $CURRENT_USER on this Mac."
