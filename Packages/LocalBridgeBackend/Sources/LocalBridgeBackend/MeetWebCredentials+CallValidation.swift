import Foundation
import GChatBridgeCore

extension MeetWebCredentials {
    /// A host preference cookie does not establish calling authentication.
    /// Probe only the read-only shell with the candidate credential, and save
    /// nothing until its normal, non-redirecting configuration is accepted.
    static func validatedCallCookies(
        _ selected: [SessionCookies.Cookie], expected: StoredSession, store: KeychainCredentialStore,
        transport: any HTTPTransport, endpoints: ChatEndpoints
    ) async throws -> [SessionCookies.Cookie] {
        guard let current = try await store.currentSession(),
              current.capturedAt == expected.capturedAt, current.expiresAt == expected.expiresAt
        else { throw MeetWebCaptureError.sessionChangedDuringVerification }
        let retained = current.credential.cookies.filter { !isMeetSpecific(domain: $0.domain) }
        guard let cookies = SessionCookies(cookies: retained + selected) else {
            throw MeetWebCaptureError.callSignInVerificationFailed
        }
        let credentials = SessionCredentials(cookies)
        let accountIndex = switch endpoints.account {
        case let .index(index): index
        case .none: 0
        }
        do {
            _ = try await MeetCallBootstrap(transport: transport, credentials: credentials)
                .loadConfiguration(accountIndex: accountIndex, userAgent: endpoints.userAgent)
        } catch {
            throw MeetWebCaptureError.callSignInVerificationFailed
        }
        guard let verified = await credentials.snapshot else {
            throw MeetWebCaptureError.callSignInVerificationFailed
        }
        // Carry forward accepted Meet-host rotations from this shell. Shared
        // Chat cookies still merge from the latest saved Chat session.
        return verified.cookies.filter { isMeetSpecific(domain: $0.domain) }
    }
}
