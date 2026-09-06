#!/bin/bash
set -euo pipefail

svndock_root="$(cd "$(dirname "$0")/.." && pwd)"
svndock_scratch="$(mktemp -d "${TMPDIR:-/tmp}/svndock-portable-directory.XXXXXX")"
trap 'rm -rf "$svndock_scratch"' EXIT
export CLANG_MODULE_CACHE_PATH="$svndock_scratch/ModuleCache"

cat > "$svndock_scratch/CoreMain.swift" <<'SWIFT'
@main
struct PortableCoreCheckMain {
    static func main() throws {
        try PortableCoreDirectoryRegressionChecks.run()
        print("Portable Core account-directory checks passed")
    }
}
SWIFT
cat > "$svndock_scratch/FinderMain.swift" <<'SWIFT'
@main
struct PortableFinderCheckMain {
    static func main() throws {
        try PortableFinderDirectoryRegressionChecks.run()
        print("Portable Finder account-directory checks passed")
    }
}
SWIFT

svndock_flags=(
    -parse-as-library -swift-version 6
    -strict-concurrency=complete -warnings-as-errors
    -D SVNDOCK_PORTABLE_SIGNED_BUILD -D SVNDOCK_PORTABLE_DIRECTORY_SMOKE
    -module-cache-path "$CLANG_MODULE_CACHE_PATH"
)
swiftc "${svndock_flags[@]}" \
    "$svndock_root"/SvnDockCore/*.swift \
    "$svndock_root/SvnDockCoreTests/PortableDirectoryRegressionChecks.swift" \
    "$svndock_scratch/CoreMain.swift" \
    -o "$svndock_scratch/core-check"
swiftc "${svndock_flags[@]}" \
    "$svndock_root/FinderExtension/SharedModels.swift" \
    "$svndock_root/FinderExtension/SharedContainer.swift" \
    "$svndock_root/FinderExtensionTests/PortableDirectoryRegressionChecks.swift" \
    "$svndock_scratch/FinderMain.swift" \
    -o "$svndock_scratch/finder-check"
"$svndock_scratch/core-check"
"$svndock_scratch/finder-check"

# Choosing two incompatible trust/configuration modes must fail at compilation.
for svndock_target in Core Finder; do
    if [[ "$svndock_target" == Core ]]; then
        svndock_sources=("$svndock_root"/SvnDockCore/*.swift)
    else
        svndock_sources=("$svndock_root/FinderExtension/SharedModels.swift" "$svndock_root/FinderExtension/SharedContainer.swift")
    fi
    if swiftc -typecheck "${svndock_flags[@]}" -D SVNDOCK_LOCAL_SIGNED_BUILD \
        "${svndock_sources[@]}" \
        > "$svndock_scratch/mixed-mode.log" 2>&1; then
        echo "error: mixed local/portable build modes unexpectedly compiled" >&2
        exit 1
    fi
    if ! grep -F 'Choose either a current-account local build' "$svndock_scratch/mixed-mode.log" >/dev/null; then
        cat "$svndock_scratch/mixed-mode.log" >&2
        echo "error: mixed-mode check failed for an unrelated reason" >&2
        exit 1
    fi
done
echo "Portable/local build mode isolation checks passed"
