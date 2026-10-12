import Foundation
import GChatBridgeCore

/// A cookie Kibble may seed into a temporary Meet web view. Values stay in
/// memory and are never written to a report.
public struct MeetWebCookieSeed: Sendable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String

    public init(name: String, value: String, domain: String, path: String) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
    }
}

public enum MeetWebCredentials {
    /// Reuse only cookies that a browser would send to Meet. Chat-host-only
    /// cookies cannot authenticate Meet and must not be copied to it.
    public static func seeds(from store: any CredentialStore) async throws -> [MeetWebCookieSeed] {
        guard let session = try await store.currentSession(),
              !session.isExpired(at: .now),
              let meet = URL(string: "https://meet.google.com/")
        else { return [] }
        return session.credential.cookies.compactMap { cookie in
            guard cookie.isSent(to: meet), let domain = cookie.domain else { return nil }
            return MeetWebCookieSeed(
                name: cookie.name, value: cookie.value, domain: domain,
                path: cookie.path ?? "/"
            )
        }
    }
}
