import Foundation
import GChatBridgeCore

/// One opaque blob, addressed by account name.
///
/// The boundary exists so the logic above it — encoding, "nothing stored"
/// versus "could not look", replacing rather than accumulating — is testable
/// without a Keychain, which the repo's testing rule requires. What is left
/// below it is `KeychainSecretStorage`, which is as thin as it can be made and
/// whose attributes are pinned by their own tests.
public protocol SecretStorage: Sendable {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String) throws
}

/// A session codec and rotation guard over host-injected secret storage.
/// The historical name preserves host source compatibility; this actor performs
/// no platform Keychain calls. Hosts supply custody under an opaque account key.
public actor KeychainCredentialStore: CredentialStore {
    /// The default Keychain service. One per app, not per account.
    public static let defaultService = "com.entersprite.kibble.session"

    /// The service the session lived under while the app was GChat. Read only
    /// when `defaultService` holds nothing, and emptied by `invalidate()`
    /// (`docs/superpowers/specs/2026-10-07-developer-id-and-kibble-identity-design.md` §3).
    static let legacyService = "com.entersprite.gchat.session"

    /// The default account name.
    ///
    /// A constant because the app holds one session today. It is a parameter
    /// rather than a hard-coded string so that supporting several signed-in
    /// Google accounts later is a caller change, not a rewrite — the protocol's
    /// account index is already configuration rather than a constant
    /// (`findings.md`), and multiple accounts is the obvious next form of that.
    public static let defaultAccount = "primary"

    private let storage: any SecretStorage
    private let legacyStorage: (any SecretStorage)?
    private let account: String

    public init(storage: any SecretStorage, legacyStorage: (any SecretStorage)? = nil, account: String) {
        self.storage = storage
        self.legacyStorage = legacyStorage
        self.account = account
    }

    public func currentSession() async throws -> StoredSession? {
        try readCurrentSession()
    }

    private func readCurrentSession() throws -> StoredSession? {
        if let data = try storage.read(account: account) {
            return try Self.decode(data)
        }
        return try migrateLegacySession()
    }

    /// The session saved before the rename, moved under `defaultService`.
    ///
    /// A refused read throws like any refused read: the launch fails and offers
    /// Sign In, and the old item stays where it was. The old item is deleted
    /// only after the new one is written; a refused delete leaves a copy the
    /// new service now shadows, which `invalidate()` still removes.
    private func migrateLegacySession() throws -> StoredSession? {
        guard let legacyStorage, let data = try legacyStorage.read(account: account) else {
            return nil
        }
        let session = try Self.decode(data)
        try storage.write(data, account: account)
        try? legacyStorage.delete(account: account)
        return session
    }

    private static func decode(_ data: Data) throws -> StoredSession {
        do {
            return try decoder.decode(StoredSession.self, from: data)
        } catch {
            // Deliberately not `nil`. Something is stored; we simply cannot use
            // it. Saying "no session" here would hide a broken storage format
            // behind a login prompt and lose the evidence with it.
            throw CredentialStoreError.unreadable
        }
    }

    public func store(_ session: StoredSession) async throws {
        try storage.write(Self.encoder.encode(session), account: account)
    }

    /// Adds Meet-host cookies to the active Chat credential atomically with
    /// respect to rotations. A missing Chat session is never created here.
    func mergeMeetCookies(
        _ cookies: [SessionCookies.Cookie], expectedStored: StoredSession
    ) throws -> Bool {
        guard let existing = try readCurrentSession() else { return false }
        // Rotations replace cookies while preserving the original sign-in's
        // capture metadata. A fresh login replaces that metadata as well.
        guard existing.capturedAt == expectedStored.capturedAt,
              existing.expiresAt == expectedStored.expiresAt
        else { throw MeetWebCaptureError.sessionChangedDuringVerification }
        let retained = existing.credential.cookies.filter {
            !MeetWebCredentials.isMeetSpecific(domain: $0.domain)
        }
        guard let merged = SessionCookies(cookies: retained + cookies) else { return false }
        try storage.write(Self.encoder.encode(StoredSession(
            credential: merged, capturedAt: existing.capturedAt, expiresAt: existing.expiresAt
        )), account: account)
        return true
    }

    /// The old service first: a session left there would come back through
    /// `currentSession()`'s migration on the next launch.
    public func invalidate() async throws {
        try legacyStorage?.delete(account: account)
        try storage.delete(account: account)
    }

    /// Dates as seconds since 1970 rather than the default, so a blob written by
    /// one release is readable by the next without the two having to agree on a
    /// formatter's configuration.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

public extension KeychainCredentialStore {
    /// Replaces the stored cookies, keeping everything else about the session.
    ///
    /// For a rotation rather than a new sign-in: the cookies changed, the
    /// session did not. `capturedAt` and `expiresAt` are carried over because a
    /// rotated `SIDCC` says nothing about when the person last authenticated,
    /// and refreshing them would hide the deadline the store exists to report.
    ///
    /// Does nothing when there is no stored session. A rotation belongs to a
    /// session; without one there is nothing for it to be a rotation *of*, and
    /// inventing a record would store a credential nobody signed in for.
    func replaceCredential(with cookies: SessionCookies) async throws {
        guard let existing = try readCurrentSession() else { return }
        let merged = MeetWebCredentials.preservingMeetCookies(from: existing.credential, in: cookies)
        try storage.write(Self.encoder.encode(StoredSession(
            credential: merged, capturedAt: existing.capturedAt, expiresAt: existing.expiresAt
        )), account: account)
    }

    /// A diagnostic session may outlive a sign-out while awaiting a response.
    /// Its rotations belong only to the capture from which it was created.
    internal func replaceCredential(
        with cookies: SessionCookies,
        belongingTo expected: StoredSession
    ) throws {
        guard let existing = try readCurrentSession(),
              existing.capturedAt == expected.capturedAt, existing.expiresAt == expected.expiresAt
        else { return }
        let merged = MeetWebCredentials.preservingMeetCookies(from: existing.credential, in: cookies)
        try storage.write(Self.encoder.encode(StoredSession(
            credential: merged, capturedAt: existing.capturedAt, expiresAt: existing.expiresAt
        )), account: account)
    }
}
