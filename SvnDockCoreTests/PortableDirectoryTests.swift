#if SVNDOCK_PORTABLE_SIGNED_BUILD
import XCTest

final class PortableDirectoryTests: XCTestCase {
    func testAccountIndependentPortableLocation() throws {
        try PortableCoreDirectoryRegressionChecks.run()
    }
}
#endif
