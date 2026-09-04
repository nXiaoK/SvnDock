import Foundation
import XCTest
@testable import SvnDockFinderExtension

final class FinderMenuSelectionResolverTests: XCTestCase {
    private let selectedFile = URL(fileURLWithPath: "/tmp/working-copy/Sources/File.swift")
    private let selectedDirectory = URL(fileURLWithPath: "/tmp/working-copy/Sources")
    private let targetedDirectory = URL(fileURLWithPath: "/tmp/working-copy/Resources")

    func testItemMenuUsesSelectionAndDoesNotFallBackToTarget() {
        XCTAssertEqual(
            resolved(.items, selected: [selectedFile], targeted: targetedDirectory),
            [selectedFile]
        )
        XCTAssertTrue(resolved(.items, selected: [], targeted: targetedDirectory).isEmpty)
    }

    func testContainerAndSidebarMenusUseTargetInsteadOfStaleSelection() {
        XCTAssertEqual(
            resolved(.container, selected: [selectedFile], targeted: targetedDirectory),
            [targetedDirectory]
        )
        XCTAssertEqual(
            resolved(.sidebar, selected: [selectedFile], targeted: targetedDirectory),
            [targetedDirectory]
        )
    }

    func testToolbarUsesSelectionThenFallsBackToTarget() {
        XCTAssertEqual(
            resolved(.toolbar, selected: [selectedFile], targeted: targetedDirectory),
            [selectedFile]
        )
        XCTAssertEqual(
            resolved(.toolbar, selected: [], targeted: targetedDirectory),
            [targetedDirectory]
        )
    }

    func testUnsupportedMenuKindFailsClosed() {
        XCTAssertTrue(
            resolved(.unsupported, selected: [selectedFile], targeted: targetedDirectory).isEmpty
        )
    }

    func testResolverCanonicalizesDeduplicatesAndRejectsNonFileURLs() {
        let duplicate = selectedDirectory.appendingPathComponent("../Sources")
        let webURL = URL(string: "https://example.com/repository")!

        XCTAssertEqual(
            resolved(
                .items,
                selected: [selectedDirectory, duplicate, webURL],
                targeted: nil
            ),
            [selectedDirectory]
        )
    }

    func testNestedItemsResolveToTheDeepestRegisteredWorkingCopy() {
        let parent = RegisteredRoot(
            id: UUID(),
            path: "/tmp/working-copy",
            displayName: "Parent",
            enabled: true
        )
        let nested = RegisteredRoot(
            id: UUID(),
            path: "/tmp/working-copy/Dependencies/Nested",
            displayName: "Nested",
            enabled: true
        )

        let resolved = RegisteredRootResolver.deepestRoot(
            containing: URL(
                fileURLWithPath: "/tmp/working-copy/Dependencies/Nested/Sources/File.swift"
            ),
            among: [parent, nested]
        )

        XCTAssertEqual(resolved?.id, nested.id)
        XCTAssertNil(RegisteredRootResolver.deepestRoot(
            containing: URL(fileURLWithPath: "/tmp/working-copy-copy/File.swift"),
            among: [parent, nested]
        ))
    }

    private func resolved(
        _ context: FinderMenuContext,
        selected: [URL],
        targeted: URL?
    ) -> [URL] {
        FinderMenuSelectionResolver.urls(
            for: context,
            selectedURLs: selected,
            targetedURL: targeted
        )
    }
}
