import Foundation

/// Why a credential store could not answer.
///
/// Small on purpose. The only distinction that changes what a caller does is
/// *was there a session and can we use it* — everything else is detail for a
/// log line.
public enum CredentialStoreError: Error, Hashable, CustomStringConvertible {
    /// Something was stored and could not be read back as a session.
    ///
    /// **Not the same as nothing being stored**, and the difference matters: an
    /// absent credential means "ask the person to sign in", while an unreadable
    /// one means the storage format broke and a working session may have just
    /// been made unreachable. Reporting the second as the first would hide a
    /// release-breaking bug behind a login prompt that appears to work.
    case unreadable

    /// The underlying store refused, e.g. it is locked or unavailable.
    ///
    /// Also not "signed out". A locked store that read as an absent credential
    /// would throw away a working session and demand a fresh two-factor login
    /// for no reason.
    case unavailable(status: Int)

    public var description: String {
        switch self {
        case .unreadable:
            "the stored credential could not be decoded"
        case let .unavailable(status):
            "the credential store is unavailable (status \(status))"
        }
    }
}

/// Where the session lives, from the core's point of view.
///
/// ## The core never touches the Keychain
///
/// This package must compile where no Keychain exists, so it declares the need
/// and lets whichever host embeds it satisfy it. That is not only portability
/// bookkeeping: it is the seam the architecture's custody tiers are expressed
/// through. The Mac app injects a Keychain-backed store and the cookies never
/// leave the device; a future bridge server injects an envelope-encrypted one
/// and can act on them at three in the morning. Same core, and the difference
/// is one injected object.
///
/// ## Why a stored session is never assumed good
///
/// Nothing here says "valid". A credential can be revoked server-side inside
/// every stated expiry — `findings.md` §11 watched a header stop authenticating
/// minutes after capture — so the only test that settles it is a request whose
/// `WizGlobalData` comes back signed in. `StoredSession.isExpired(at:)` exists
/// to skip work that is certainly pointless, never to promise work will
/// succeed.
public protocol CredentialStore: Sendable {
    /// The stored session, or `nil` when there is none.
    ///
    /// Throws rather than returning `nil` when the store itself failed, because
    /// "no credential" and "could not look" lead to opposite recoveries.
    func currentSession() async throws -> StoredSession?

    /// Persists a session, replacing any previous one.
    func store(_ session: StoredSession) async throws

    /// Discards the stored session. Not an error when there was none.
    func invalidate() async throws
}
