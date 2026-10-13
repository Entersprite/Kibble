import Foundation
import LocalBridgeBackend

public struct MeetWebProbeCookie: Sendable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String
}

public enum MeetWebProbeSaveError: Error, Sendable {
    case accountVerificationFailed(detail: String)
    case accountMismatch
    case sessionChangedDuringVerification
}

/// The diagnostic call window gets the existing account's Meet-scoped cookies
/// without knowing how Kibble stores its credential.
public enum MeetWebProbeSession {
    public static func cookies() async throws -> [MeetWebProbeCookie] {
        try await MeetWebCredentials.seeds(from: KeychainCredentialStore()).map {
            MeetWebProbeCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path)
        }
    }

    /// Called only by the owner's explicit button in the temporary Meet view.
    /// Values are handed straight to Keychain custody, never to a report.
    public static func saveMeetCookies(_ cookies: [HTTPCookie]) async throws -> Int {
        let captured = cookies.map {
            CapturedCookie(
                name: $0.name, value: $0.value, domain: $0.domain, path: $0.path,
                isSecure: $0.isSecure, isHTTPOnly: $0.isHTTPOnly, expiresAt: $0.expiresDate
            )
        }
        do {
            return try await MeetWebCredentials.save(captured: captured, to: KeychainCredentialStore())
        } catch let error as MeetWebCaptureError {
            switch error {
            case .accountVerificationFailed:
                throw MeetWebProbeSaveError.accountVerificationFailed(
                    detail: error.verificationDescription ?? "Account verification failed."
                )
            case .accountMismatch: throw MeetWebProbeSaveError.accountMismatch
            case .sessionChangedDuringVerification:
                throw MeetWebProbeSaveError.sessionChangedDuringVerification
            }
        }
    }
}
