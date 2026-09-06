#if SVNDOCK_PORTABLE_SIGNED_BUILD
import Darwin
import Foundation
#if !SVNDOCK_PORTABLE_DIRECTORY_SMOKE
@testable import SvnDockFinderExtension
#endif

enum PortableFinderDirectoryRegressionChecks {
    static func run() throws {
        for home in ["/Users/build runner", "/Volumes/数据/recipient"] {
            let resolved = try SharedContainer.portableSignedDirectory(accountHome: home, realUserID: 501, effectiveUserID: 501)
            try check(resolved.path == home + "/Library/Application Support/SvnDock",
                      "Finder uses the same fixed home-relative entitlement path for each account")
        }
        let invalidHomes: [String?] = [nil, "", "~recipient", "relative/home", "/", "/Users/..", "/var/empty", "/dev/null", "/Users/nul\0home"]
        for home in invalidHomes {
            do {
                _ = try SharedContainer.portableSignedDirectory(accountHome: home, realUserID: 501, effectiveUserID: 501)
                throw PortableFinderDirectoryFailure(message: "Finder must reject an invalid account home")
            } catch SharedContainerError.invalidPortableAccountDirectory { }
        }
        for ids in [(uid_t(0), uid_t(0)), (501, 0), (501, 502)] {
            do {
                _ = try SharedContainer.portableSignedDirectory(accountHome: "/Users/recipient", realUserID: ids.0, effectiveUserID: ids.1)
                throw PortableFinderDirectoryFailure(message: "Finder must reject root and identity mismatches")
            } catch SharedContainerError.invalidPortableAccountDirectory { }
        }
        if getuid() != 0 && getuid() == geteuid() {
            let expected = try SharedContainer.portableSignedDirectory()
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("svndock-portable-bundle-\(UUID()).bundle", isDirectory: true)
            let contents = temporary.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let plist: [String: Any] = [
                "CFBundleIdentifier": "com.svndock.portable-fixture.\(UUID().uuidString)",
                "CFBundlePackageType": "BNDL",
                "SvnDockLocalSharedDirectory": "/Users/runner/Library/Application Support/SvnDock"
            ]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            guard let bundle = Bundle(url: temporary) else {
                throw PortableFinderDirectoryFailure(message: "could not create isolated bundle fixture")
            }
            let container = SharedContainer(bundle: bundle)
            try check(container.sharedDirectoryURL == expected && container.containerURL == nil,
                      "portable Finder ignores a stale builder account path and does not request an unavailable App Group")
        }
    }
    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw PortableFinderDirectoryFailure(message: message) }
    }
}
private struct PortableFinderDirectoryFailure: Error { let message: String }
#endif
