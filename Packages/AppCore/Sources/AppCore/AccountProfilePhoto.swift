import Foundation

/// A bounded client cache of an account photo fetched through its service loader.
/// It is display metadata, retained with the account profile while signed out.
public struct AccountProfilePhoto: Codable, Equatable, Sendable {
    public static let maximumBytes = 512 * 1024
    public let url: URL
    public let data: Data

    public init?(url: URL, data: Data) {
        guard !data.isEmpty, data.count <= Self.maximumBytes,
              url.absoluteString.utf8.count <= 4096 else { return nil }
        self.url = url; self.data = data
    }
}
