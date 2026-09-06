#!/bin/bash
# Run Finder cache, menu and badge regressions with Command Line Tools.
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/svndock-finder-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT

# Reuse the XCTest cases unchanged; these small assertion adapters allow the
# same cases to run on machines with Command Line Tools and no Xcode/XCTest.
sed '/^import XCTest$/d; /^@testable import SvnDockFinderExtension$/d' \
    "$repository_root/FinderExtensionTests/SharedStateStoreTests.swift" \
    > "$test_directory/SharedStateStoreTests.swift"
sed '/^import XCTest$/d; /^@testable import SvnDockFinderExtension$/d' \
    "$repository_root/FinderExtensionTests/FinderMenuSelectionResolverTests.swift" \
    > "$test_directory/FinderMenuSelectionResolverTests.swift"
sed '/^import XCTest$/d; /^@testable import SvnDockFinderExtension$/d' \
    "$repository_root/FinderExtensionTests/FinderBadgePresentationTests.swift" \
    > "$test_directory/FinderBadgePresentationTests.swift"
sed '/^import XCTest$/d; /^@testable import SvnDockFinderExtension$/d' \
    "$repository_root/FinderExtensionTests/FinderBadgeImageTests.swift" \
    > "$test_directory/FinderBadgeImageTests.swift"

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
        let menuTests = FinderMenuSelectionResolverTests()
        menuTests.testItemMenuUsesSelectionAndDoesNotFallBackToTarget()
        menuTests.testContainerAndSidebarMenusUseTargetInsteadOfStaleSelection()
        menuTests.testToolbarUsesSelectionThenFallsBackToTarget()
        menuTests.testUnsupportedMenuKindFailsClosed()
        menuTests.testResolverCanonicalizesDeduplicatesAndRejectsNonFileURLs()
        menuTests.testNestedItemsResolveToTheDeepestRegisteredWorkingCopy()
        let badgeTests = FinderBadgePresentationTests()
        badgeTests.testDirectStateNeverFallsBackToAncestorDisplayBadge()
        badgeTests.testCleanRequiresFreshRootAndUnknownNeverBecomesGreen()
        try badgeTests.testLegacySnapshotRemainsUnknownAndGlobalDateDoesNotRefreshAnotherRoot()
        badgeTests.testFreshnessHandlesTimestampVariantsBoundaryAndFutureClock()
        badgeTests.testRepaintingOnlyUpdatesRequestedPathsAndClearsRemovedBadges()
        badgeTests.testRequestedPathCapDeduplicationAndDirectoryScope()
        badgeTests.testRecentDirectoryLimitAndEndObservationPreservesOtherVisibleDirectory()
        try badgeTests.testRequestEncodingRespectsDirectoryItemAndByteBudgets()
        badgeTests.testSymbolSpecificationsGiveEachStateAColorShapeAndLabel()
        try badgeTests.testRequestWriterUsesPrivatePermissionsAndStableInstanceFile()
        try badgeTests.testRootLoaderFiltersDisabledAndCanonicalizesRoots()
        let imageTests = FinderBadgeImageTests()
        try imageTests.testEveryStateProducesVisibleStandardAndRetinaBitmaps()
        try imageTests.testFilledStatesKeepWhiteGlyphsAndTheirStateColor()
        try imageTests.testUnknownOutlineRemainsGrayWithoutWhiteFill()
        try imageTests.testFilledStatesRemainDistinguishableWhenColorsMatch()
        try imageTests.testSecureArchivePreservesBitmapSizesAndPixels()
        try imageTests.testTIFFPreservesTransparentColoredBitmapContent()
        imageTests.testUnavailableSymbolDoesNotProduceABlankBadge()
        try imageTests.testRenderingPreservesTheCallingGraphicsContext()
        print("Passed 30 Finder shared-state, menu, badge and image regression tests")
    }
}
SWIFT

xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -D SVNDOCK_LOCAL_SIGNED_BUILD \
    -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$test_directory/ModuleCache" \
    -framework AppKit \
    "$repository_root/FinderExtension/SharedModels.swift" \
    "$repository_root/FinderExtension/SharedContainer.swift" \
    "$repository_root/FinderExtension/FinderMenuSelectionResolver.swift" \
    "$repository_root/FinderExtension/FinderBadgeImages.swift" \
    "$test_directory/SharedStateStoreTests.swift" \
    "$test_directory/FinderMenuSelectionResolverTests.swift" \
    "$test_directory/FinderBadgePresentationTests.swift" \
    "$test_directory/FinderBadgeImageTests.swift" \
    "$test_directory/Assertions.swift" \
    -o "$test_directory/FinderRegressionTests"
"$test_directory/FinderRegressionTests"
