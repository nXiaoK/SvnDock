import Foundation

/// Presentation-only classification. None of these values changes SVN status
/// or asserts that a whitespace edit is semantically safe to discard.
public enum SVNLocalDifferenceKind: String, Hashable, Sendable {
    case lineEndingsOnly
    case whitespaceOnly
    case substantive
    case unknown
}
