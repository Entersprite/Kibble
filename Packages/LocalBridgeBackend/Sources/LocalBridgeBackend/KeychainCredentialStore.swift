import ChatKit
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
    private let expectedGeneration: String?

    public init(
        storage: any SecretStorage, legacyStorage: (any SecretStorage)? = nil,
        account: String, expectedGeneration: String? = nil
    ) {
        self.storage = storage
        self.legacyStorage = legacyStorage
        self.account = account
        self.expectedGeneration = expectedGeneration
    }

    public func currentSession() async throws -> StoredSession? {
        try readCurrentSession()
    }

    private func readCurrentSession() throws -> StoredSession? {
        try snapshot()?.session
    }

    /// One actor turn reads the session and its capture identity together.
    func snapshot() throws -> CredentialSnapshot? {
        let data: Data?
        if let current = try storage.read(account: account) {
            data = current
        } else if let legacyStorage, let legacy = try legacyStorage.read(account: account) {
            _ = try Self.decode(legacy)
            try storage.write(legacy, account: account)
            try? legacyStorage.delete(account: account)
            data = legacy
        } else {
            data = nil
        }
        guard let data else { return nil }
        let result = try Self.decode(data)
        if let expectedGeneration, result.generation != expectedGeneration {
            throw SessionCustodyError.sessionChanged
        }
        return result
    }

    private static func decode(_ data: Data) throws -> CredentialSnapshot {
        do {
            return try decoder.decode(CredentialSnapshot.self, from: data)
        } catch {
            throw CredentialStoreError.unreadable
        }
    }

    private func write(_ snapshot: CredentialSnapshot) throws {
        try storage.write(Self.encoder.encode(snapshot), account: account)
    }

    public func store(_ session: StoredSession) async throws {
        guard expectedGeneration == nil else { throw SessionCustodyError.sessionChanged }
        try write(CredentialSnapshot(session: session, generation: UUID().uuidString))
    }

    /// Installs a verified login in a fresh immutable generation slot. Repeating
    /// installation after a crash is safe; a different generation cannot replace it.
    public func install(_ candidate: VerifiedProviderSession, generation: String) async throws {
        guard !generation.isEmpty, expectedGeneration == nil || expectedGeneration == generation else {
            throw SessionCustodyError.sessionChanged
        }
        let session = try await candidate.currentSession()
        if let existing = try snapshot() {
            guard existing.generation == generation,
                  existing.verifiedIdentity == candidate.selfID.rawValue,
                  existing.sourceGeneration == candidate.sourceGeneration
            else { throw SessionCustodyError.occupied }
            return
        }
        try write(CredentialSnapshot(
            session: session,
            generation: generation,
            verifiedIdentity: candidate.selfID.rawValue,
            sourceGeneration: candidate.sourceGeneration
        ))
    }

    /// Host recovery can recognize an installed generation without reopening a
    /// discarded staging login. This is vault metadata, never caller authority.
    public func installedIdentity() throws -> ChatKit.Member.ID? {
        try snapshot()?.verifiedIdentity.map(ChatKit.Member.ID.init(rawValue:))
    }

    /// Adds Meet-host cookies to the active Chat credential atomically with
    /// respect to rotations. A missing Chat session is never created here.
    func mergeMeetCookies(
        _ cookies: [SessionCookies.Cookie], expected: CredentialSnapshot
    ) throws -> Bool {
        guard let current = try snapshot() else { return false }
        let existing = current.session
        guard current.matches(expected) else { throw MeetWebCaptureError.sessionChangedDuringVerification }
        let retained = existing.credential.cookies.filter {
            !MeetWebCredentials.isMeetSpecific(domain: $0.domain)
        }
        guard let merged = SessionCookies(cookies: retained + cookies) else { return false }
        try write(current.replacingCookies(merged))
        return true
    }

    /// The old service first: a session left there would come back through
    /// `currentSession()`'s migration on the next launch.
    public func invalidate() async throws {
        if expectedGeneration != nil {
            _ = try snapshot()
        }
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
        guard let current = try snapshot() else { return }
        let existing = current.session
        let merged = MeetWebCredentials.preservingMeetCookies(from: existing.credential, in: cookies)
        try write(current.replacingCookies(merged))
    }

    /// A diagnostic session may outlive a sign-out while awaiting a response.
    /// Its rotations belong only to the capture from which it was created.
    internal func replaceCredential(
        with cookies: SessionCookies,
        belongingTo expected: CredentialSnapshot
    ) throws {
        guard let current = try snapshot(), current.matches(expected) else { return }
        let existing = current.session
        let merged = MeetWebCredentials.preservingMeetCookies(from: existing.credential, in: cookies)
        try write(current.replacingCookies(merged))
    }
}
