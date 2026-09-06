#if SVNDOCK_PORTABLE_SIGNED_BUILD
import Darwin
import Foundation
#if !SVNDOCK_PORTABLE_DIRECTORY_SMOKE
@testable import SvnDockCore
#endif

enum PortableCoreDirectoryRegressionChecks {
    static func run() throws {
        let first = try FinderSharedStoreLocation.portableSignedDirectory(
            accountHome: "/Users/build runner", realUserID: 501, effectiveUserID: 501
        )
        let second = try FinderSharedStoreLocation.portableSignedDirectory(
            accountHome: "/Volumes/数据/recipient", realUserID: 502, effectiveUserID: 502
        )
        try check(first.path == "/Users/build runner/Library/Application Support/SvnDock",
                  "spaces in an account home preserve the narrowly scoped relative store path")
        try check(second.path == "/Volumes/数据/recipient/Library/Application Support/SvnDock" && second != first,
                  "recipient accounts resolve their own data directory rather than a build account path")
        let invalidHomes: [String?] = [nil, "", "~recipient", "relative/home", "/", "/Users/..", "/var/empty", "/dev/null", "/Users/nul\0home"]
        for home in invalidHomes {
            do {
                _ = try FinderSharedStoreLocation.portableSignedDirectory(accountHome: home, realUserID: 501, effectiveUserID: 501)
                throw PortableCoreDirectoryFailure(message: "invalid account home must fail closed")
            } catch FinderSharedStoreError.invalidPortableAccountDirectory { }
        }
        for ids in [(uid_t(0), uid_t(0)), (501, 0), (501, 502)] {
            do {
                _ = try FinderSharedStoreLocation.portableSignedDirectory(accountHome: "/Users/recipient", realUserID: ids.0, effectiveUserID: ids.1)
                throw PortableCoreDirectoryFailure(message: "root and identity mismatches must be rejected")
            } catch FinderSharedStoreError.invalidPortableAccountDirectory { }
        }
        if getuid() != 0 && getuid() == geteuid() {
            guard let expectedHome = getpwuid(getuid())?.pointee.pw_dir else {
                throw PortableCoreDirectoryFailure(message: "test account is unavailable")
            }
            let expected = URL(fileURLWithPath: String(cString: expectedHome), isDirectory: true)
                .appendingPathComponent("Library/Application Support/SvnDock", isDirectory: true).standardizedFileURL
            try check(try FinderSharedStoreLocation.portableSignedDirectory() == expected,
                      "runtime lookup uses the account database without reading or writing user state")
        }
    }

    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw PortableCoreDirectoryFailure(message: message) }
    }
}
private struct PortableCoreDirectoryFailure: Error { let message: String }
#endif
