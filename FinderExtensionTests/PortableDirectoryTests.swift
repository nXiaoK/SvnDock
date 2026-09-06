#if SVNDOCK_PORTABLE_SIGNED_BUILD
import XCTest

final class PortableDirectoryTests: XCTestCase {
    func testPortableFinderUsesTheRecipientAccountDirectory() throws {
        try PortableFinderDirectoryRegressionChecks.run()
    }
}
#endif
