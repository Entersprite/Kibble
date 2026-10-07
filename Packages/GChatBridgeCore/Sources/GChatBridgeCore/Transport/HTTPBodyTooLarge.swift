import Foundation

/// A body past `HTTPRequest.maxBodyBytes`, refused before it was held whole.
/// Carries the limit, never the URL.
public struct HTTPBodyTooLarge: Error, Equatable, Sendable {
    public let limit: Int

    public init(limit: Int) {
        self.limit = limit
    }
}
