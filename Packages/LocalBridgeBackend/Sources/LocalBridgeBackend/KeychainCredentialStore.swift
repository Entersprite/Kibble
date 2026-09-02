import Foundation
import GChatBridgeCore
import Security

/// One opaque blob, addressed by account name.
///
/// The boundary exists so the logic above it — encoding, "nothing stored"
/// versus "could not look", replacing rather than accumulating — is testable
/// without a Keychain, which the repo's testing rule requires. What is left
/// below it is `KeychainSecretStorage`, which is as thin as it can be made and
/// whose attributes are pinned by their own tests.
protocol SecretStorage: Sendable {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String) throws
}

/// The Mac's credential custody: the session lives in the Keychain and never
/// leaves the device.
///
/// This is what retires `cookie-header.txt` — a live Google session sitting in
/// plain text inside the app container, which was the developer escape hatch
/// and was never the product.
public actor KeychainCredentialStore: CredentialStore {
    /// The default Keychain service. One per app, not per account.
    public static let defaultService = "com.entersprite.gchat.session"

    /// The default account name.
    ///
    /// A constant because the app holds one session today. It is a parameter
    /// rather than a hard-coded string so that supporting several signed-in
    /// Google accounts later is a caller change, not a rewrite — the protocol's
    /// account index is already configuration rather than a constant
    /// (`findings.md`), and multiple accounts is the obvious next form of that.
    public static let defaultAccount = "primary"

    private let storage: any SecretStorage
    private let account: String

    public init(
        service: String = KeychainCredentialStore.defaultService,
        account: String = KeychainCredentialStore.defaultAccount
    ) {
        self.init(storage: KeychainSecretStorage(service: service), account: account)
    }

    init(storage: any SecretStorage, account: String) {
        self.storage = storage
        self.account = account
    }

    public func currentSession() async throws -> StoredSession? {
        guard let data = try storage.read(account: account) else { return nil }
        do {
            return try Self.decoder.decode(StoredSession.self, from: data)
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

    public func invalidate() async throws {
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

// MARK: - The actual Keychain

/// The only code here that calls `SecItem`.
///
/// Kept to four operations with no branching beyond add-versus-update, because
/// this is the part no unit test can exercise. Its attribute choices are the
/// security-relevant decisions, and those *are* tested — see
/// `KeychainQueryTests`.
struct KeychainSecretStorage: SecretStorage {
    let service: String

    /// Identifies the item. Never includes the value or the return flags, so
    /// the same dictionary can address a read, an update and a delete.
    ///
    /// `kSecAttrSynchronizable: false` is load-bearing rather than tidy: a
    /// synchronisable item rides iCloud Keychain to the person's other devices,
    /// and "the session cookies never leave the Mac" is the architecture's
    /// custody claim and the whole difference between the E2E tier and the
    /// hosted one.
    ///
    /// `useDataProtection` selects **which keychain**, and it is stated rather
    /// than defaulted-into. `false` is the legacy file-based keychain, where
    /// `kSecAttrAccessible` is ignored and item ACLs bind to the accessing
    /// binary's code signature - the source of the login-password dialog on a
    /// signature change. `true` is the data-protection keychain, which honours
    /// `kSecAttrAccessible` and never prompts, but is a **separate store**
    /// whose items a sandboxed app can only reach through an access group its
    /// signing identity supplies. `findings.md` §19.4 records the measurement.
    static func baseQuery(
        service: String,
        account: String,
        useDataProtection: Bool = false
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: useDataProtection
        ]
    }

    /// The attributes for creating the item.
    ///
    /// `AfterFirstUnlockThisDeviceOnly` because the menu-bar agent reconnects
    /// after a reboot without anyone opening a window, so the credential has to
    /// be readable once the machine has been unlocked at least once — and
    /// `ThisDeviceOnly` for the same custody reason as above. Note this
    /// attribute is **only honoured when `useDataProtection` is true**; under
    /// the legacy keychain it is accepted and ignored.
    static func addAttributes(
        service: String,
        account: String,
        data: Data,
        useDataProtection: Bool = false
    ) -> [String: Any] {
        var attributes = baseQuery(
            service: service, account: account, useDataProtection: useDataProtection
        )
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return attributes
    }

    // MARK: - `SecretStorage` conformance (legacy keychain, unchanged behaviour)

    func read(account: String) throws -> Data? {
        try read(account: account, useDataProtection: false)
    }

    func write(_ data: Data, account: String) throws {
        try write(data, account: account, useDataProtection: false)
    }

    func delete(account: String) throws {
        try delete(account: account, useDataProtection: false)
    }

    // MARK: - The same three operations, naming which keychain

    /// Not part of `SecretStorage`: only code that already holds a concrete
    /// `KeychainSecretStorage` — the data-protection self-check — needs to name
    /// the keychain explicitly, and widening the protocol for that one caller
    /// would force every fake conformer to grow a parameter it never uses.
    func read(account: String, useDataProtection: Bool) throws -> Data? {
        var query = Self.baseQuery(
            service: service, account: account, useDataProtection: useDataProtection
        )
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            // A generic-password item with no data is not a credential, and
            // returning empty `Data` would send it on to a decoder that reports
            // it as a format break rather than as an absent session.
            guard let data = item as? Data, !data.isEmpty else { return nil }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.unavailable(status: Int(status))
        }
    }

    func write(_ data: Data, account: String, useDataProtection: Bool) throws {
        let query = Self.baseQuery(
            service: service, account: account, useDataProtection: useDataProtection
        )
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let added = SecItemAdd(
                Self.addAttributes(
                    service: service,
                    account: account,
                    data: data,
                    useDataProtection: useDataProtection
                ) as CFDictionary,
                nil
            )
            guard added == errSecSuccess else {
                throw CredentialStoreError.unavailable(status: Int(added))
            }
        default:
            throw CredentialStoreError.unavailable(status: Int(status))
        }
    }

    func delete(account: String, useDataProtection: Bool) throws {
        let status = SecItemDelete(
            Self.baseQuery(
                service: service, account: account, useDataProtection: useDataProtection
            ) as CFDictionary
        )
        // Deleting what was never there is the caller's intended end state.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.unavailable(status: Int(status))
        }
    }
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
        guard let existing = try await currentSession() else { return }
        try await store(
            StoredSession(
                credential: cookies,
                capturedAt: existing.capturedAt,
                expiresAt: existing.expiresAt
            )
        )
    }
}
