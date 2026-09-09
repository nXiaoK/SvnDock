import Foundation
import SvnDockCore

struct SvnDockCheckoutRequest: Sendable {
    let repositoryURL: URL
    let destinationURL: URL

    init(repositoryAddress: String, localPath: String) throws {
        repositoryURL = try SVNCheckout.repositoryURL(from: repositoryAddress)
        let path = (localPath as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), !path.contains("\0"), path != "/" else {
            throw SVNCheckoutError.invalidDestination
        }
        destinationURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}
