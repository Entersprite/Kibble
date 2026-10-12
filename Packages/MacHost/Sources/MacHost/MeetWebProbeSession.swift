import Foundation
import LocalBridgeBackend

public struct MeetWebProbeCookie: Sendable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String
}

/// The diagnostic call window gets the existing account's Meet-scoped cookies
/// without knowing how Kibble stores its credential.
public enum MeetWebProbeSession {
    public static func cookies() async throws -> [MeetWebProbeCookie] {
        try await MeetWebCredentials.seeds(from: KeychainCredentialStore()).map {
            MeetWebProbeCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path)
        }
    }
}
