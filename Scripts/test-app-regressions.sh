#!/bin/bash
set -euo pipefail

svndock_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$svndock_root"
export CLANG_MODULE_CACHE_PATH="$svndock_root/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"

swift build --disable-sandbox -c release --product SvnDock \
    -Xswiftc -swift-version -Xswiftc 6 \
    -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
svndock_bin="$(swift build --disable-sandbox -c release --show-bin-path)"
svndock_checks=(SvnDockAppTests/*Checks.swift)
svndock_test_flags=(-D SVNDOCK_APP_SMOKE)
if [[ "${1:-}" == "--svn-safety" ]]; then
    svndock_checks=(SvnDockAppTests/SVNSafetyRegressionChecks.swift)
    svndock_test_flags+=(-D SVNDOCK_SAFETY_SMOKE)
fi

# Exercise the production store and service without requiring XCTest or
# launching the GUI. XCTest invokes these same checks on full Xcode installs.
swiftc -parse-as-library -O -swift-version 6 \
    -strict-concurrency=complete -warnings-as-errors \
    "${svndock_test_flags[@]}" -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    -I "$svndock_bin/Modules" \
    SvnDockApp/Models/*.swift SvnDockApp/Store/*.swift \
    SvnDockApp/Views/DiffContentView.swift SvnDockApp/Views/StatusVisuals.swift \
    "${svndock_checks[@]}" SvnDockAppTests/SmokeMain.swift \
    "$svndock_bin"/SvnDockCore.build/*.o \
    -o "$svndock_bin/SvnDockAppRegressionSmoke"
"$svndock_bin/SvnDockAppRegressionSmoke" "$@"
