import Foundation
import GChatBridgeCore
import URLSessionTransport

/// What a host may say about the stored session without holding the credential.
///
/// Counts and dates. The credential itself stays inside this package, which is
/// what lets the app render a "signed in, expires in 9 days" line without ever
/// naming a type from `GChatBridgeCore`.
public struct StoredSessionSummary: Sendable, Hashable, CustomStringConvertible {
    public let cookieCount: Int
    public let capturedAt: Date
    public let expiresAt: Date?
    public let isExpired: Bool

    /// Whole days left, floored, or `nil` when no expiry was stated.
    public let daysRemaining: Int?

    /// A sentence for a window. Names no cookie and carries no value.
    public var description: String {
        var parts = ["\(cookieCount) cookies"]
        if isExpired {
            parts.append("expired")
        } else if let daysRemaining {
            parts.append("expires in \(daysRemaining) days")
        } else {
            parts.append("no stated expiry")
        }
        return parts.joined(separator: ", ")
    }
}

public extension KeychainCredentialStore {
    /// What is stored, described safely, or `nil` when nothing is.
    ///
    /// Takes the instant rather than reading a clock so the answer is testable
    /// and so a caller rendering several fields cannot have them disagree by a
    /// tick.
    func summary(at instant: Date) async throws -> StoredSessionSummary? {
        guard let session = try await currentSession() else { return nil }
        return StoredSessionSummary(
            cookieCount: session.credential.count,
            capturedAt: session.capturedAt,
            expiresAt: session.expiresAt,
            isExpired: session.isExpired(at: instant),
            daysRemaining: session.remainingLifetime(at: instant).map { Int($0 / 86400) }
        )
    }
}

public extension CookieCapture {
    /// Persists this capture's credential.
    ///
    /// `false` means there was nothing in scope to persist — a capture taken
    /// before Chat issued its own cookies, most likely — and the caller should
    /// say so rather than report a successful sign-in. Any previously stored
    /// session is left alone in that case, because replacing a working
    /// credential with nothing is strictly worse than keeping it.
    @discardableResult
    func save(to store: KeychainCredentialStore) async throws -> Bool {
        guard let session else { return false }
        try await store.store(session)
        return true
    }
}

public extension LocalBridgeBackend {
    /// Builds a bridge from the stored session, or `nil` when there is none.
    ///
    /// **An expired session still builds one.** Expiry is a lower bound on
    /// trouble and never a verdict — a credential can be revoked well inside
    /// every stated expiry (`findings.md` §11), and one past its expiry can
    /// still be accepted. The request that settles it costs a single round
    /// trip, and refusing to make it would promote a guess to a policy.
    static func using(_ store: KeychainCredentialStore) async throws -> LocalBridgeBackend? {
        guard let session = try await store.currentSession() else { return nil }
        return LocalBridgeBackend(
            cookies: session.credential,
            transport: URLSessionTransport()
        )
    }
}

public extension KeychainCredentialStore {
    /// The account the self-check writes to.
    ///
    /// Separate from `defaultAccount` so running a diagnostic can never destroy
    /// somebody's live session - the check deletes what it wrote, and pointing
    /// it at the real account would make that deletion a logout.
    static let selfCheckAccount = "selfcheck"

    /// A store aimed at the self-check account.
    static func forSelfCheck() -> KeychainCredentialStore {
        KeychainCredentialStore(account: selfCheckAccount)
    }

    /// Round-trips a throwaway credential and reports whether it worked.
    ///
    /// Whether this app can use the Keychain at all depends on how it was
    /// signed rather than on anything in this repository, and the failure is a
    /// silent `-34018` that reads exactly like "no session stored". So the
    /// question gets asked directly, and the answer is a sentence rather than a
    /// status code.
    func selfCheck() async -> String {
        let probe = StoredSession(
            credential: SessionCookies(cookies: [
                SessionCookies.Cookie(name: "GCHAT-SELFCHECK", value: "not-a-credential")
            ])!,
            capturedAt: Date(timeIntervalSince1970: 0),
            expiresAt: nil
        )
        do {
            try await store(probe)
            let read = try await currentSession()
            try await invalidate()
            guard read?.credential["GCHAT-SELFCHECK"] == "not-a-credential" else {
                return "FAIL - the Keychain accepted a write and returned something else."
            }
            return "PASS - this build can write and read the Keychain."
        } catch {
            // Best effort: if the write landed and the read failed, leaving the
            // probe behind would be litter.
            try? await invalidate()
            return "FAIL - \(KeychainDiagnosis.explain(error))"
        }
    }
}
