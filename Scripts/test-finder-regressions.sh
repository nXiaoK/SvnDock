#!/bin/bash
# Run Finder cache regressions with Command Line Tools (XCTest is optional).
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/svndock-finder-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT

# Reuse the XCTest cases unchanged; these small assertion adapters allow the
# same cases to run on machines with Command Line Tools and no Xcode/XCTest.
sed '/^import XCTest$/d; /^@testable import SvnDockFinderExtension$/d' \
    "$repository_root/FinderExtensionTests/SharedStateStoreTests.swift" \
    > "$test_directory/SharedStateStoreTests.swift"

cat > "$test_directory/Assertions.swift" <<'SWIFT'
import Foundation

class XCTestCase {}

func XCTAssertEqual<T: Equatable>(
    _ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line
) {
    precondition(actual == expected, "Expected \(expected), found \(actual)", file: file, line: line)
}

func XCTAssertTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(value, "Expected true", file: file, line: line)
}

func XCTAssertNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    precondition(value == nil, "Expected nil", file: file, line: line)
}

@main
struct FinderRegressionMain {
    static func main() throws {
        let tests = SharedStateStoreTests()
        try tests.testUnchangedCallbacksReuseDecodedSnapshots()
        try tests.testBadgeReplacementReloadsOnlyBadgesEvenWithSameSizeAndDate()
        try tests.testRemovedAndMalformedRegistryImmediatelyClearCachedRoots()
        try tests.testReplacementDuringReadIsDetectedOnNextReload()
        try tests.testConcurrentReloadCannotRestoreStaleRoots()
        print("Passed 5 Finder shared-state regression tests")
    }
}
SWIFT

xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$test_directory/ModuleCache" \
    "$repository_root/FinderExtension/SharedModels.swift" \
    "$repository_root/FinderExtension/SharedContainer.swift" \
    "$test_directory/SharedStateStoreTests.swift" \
    "$test_directory/Assertions.swift" \
    -o "$test_directory/FinderRegressionTests"
"$test_directory/FinderRegressionTests"
