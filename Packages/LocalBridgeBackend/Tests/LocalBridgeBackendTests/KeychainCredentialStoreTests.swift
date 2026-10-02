import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The credential store's logic, with the Keychain itself faked.
///
/// The repo's rule is that tests need no Keychain, so the `SecItem` calls sit
/// behind `SecretStorage` and everything above that boundary is exercised here.
/// What is left unfaked is one thin adapter, whose attributes are pinned
/// separately below.
struct KeychainCredentialStoreTests {
    private let now = Date(timeIntervalSince1970: 1_788_166_800)

    /// A `SecretStorage` that lives in memory and can be told to fail.
    private final class FakeStorage: SecretStorage, @unchecked Sendable {
        var items: [String: Data] = [:]
        var readError: (any Error)?
        var writeError: (any Error)?
        private(set) var writeCount = 0

        func read(account: String) throws -> Data? {
            if let readError {
                throw readError
            }
            return items[account]
        }

        func write(_ data: Data, account: String) throws {
            if let writeError {
                throw writeError
            }
            writeCount += 1
            items[account] = data
        }

        func delete(account: String) throws {
            items[account] = nil
        }
    }

    private struct Boom: Error {}

    private func session(_ names: [String] = ["COMPASS", "OSID"], expiresAt: Date? = nil) -> StoredSession {
        StoredSession(
            credential: SessionCookies(cookies: names.map {
                SessionCookies.Cookie(name: $0, value: "value-for-\($0)")
            })!,
            capturedAt: now,
            expiresAt: expiresAt
        )
    }

    private func store(_ storage: FakeStorage) -> KeychainCredentialStore {
        KeychainCredentialStore(storage: storage, account: "test")
    }

    // MARK: - The ordinary path

    @Test func nothingStoredIsNoSession() async throws {
        #expect(try await store(FakeStorage()).currentSession() == nil)
    }

    @Test func aStoredSessionComesBackIntact() async throws {
        let storage = FakeStorage()
        let subject = store(storage)
        let original = session(["COMPASS", "OSID"], expiresAt: now.addingTimeInterval(9 * 86400))
        try await subject.store(original)
        #expect(try await subject.currentSession() == original)
    }

    @Test func storingAgainReplacesRatherThanAccumulating() async throws {
        let storage = FakeStorage()
        let subject = store(storage)
        try await subject.store(session(["OLD"]))
        try await subject.store(session(["NEW"]))
        let loaded = try await subject.currentSession()
        #expect(loaded?.credential.cookies.map(\.name) == ["NEW"])
        #expect(storage.items.count == 1)
    }

    @Test func invalidatingRemovesTheCredential() async throws {
        let subject = store(FakeStorage())
        try await subject.store(session())
        try await subject.invalidate()
        #expect(try await subject.currentSession() == nil)
    }

    @Test func invalidatingWhenNothingIsStoredIsNotAnError() async throws {
        try await store(FakeStorage()).invalidate()
    }

    // MARK: - Failures that must not read as "signed out"

    /// The distinction the whole type turns on.
    ///
    /// A locked or broken Keychain is **not** an absent credential. Collapsing
    /// the two would make the app throw away a working session and ask a person
    /// to complete a two-factor login for no reason - and it would do it
    /// silently, which is how this class of bug survives.
    @Test func aStorageFailureIsReportedRatherThanReadAsNoSession() async throws {
        let storage = FakeStorage()
        storage.readError = Boom()
        await #expect(throws: (any Error).self) {
            try await store(storage).currentSession()
        }
    }

    @Test func aWriteFailureIsReported() async throws {
        let storage = FakeStorage()
        storage.writeError = Boom()
        await #expect(throws: (any Error).self) {
            try await store(storage).store(session())
        }
    }

    /// A blob written by some other version of this app is unusable, and
    /// pretending it is absent would hide a format break behind a login prompt.
    @Test func anUnreadableBlobIsReportedRatherThanTreatedAsAbsent() async throws {
        let storage = FakeStorage()
        storage.items["test"] = Data("not json".utf8)
        await #expect(throws: CredentialStoreError.unreadable) {
            try await store(storage).currentSession()
        }
    }

    /// Decodable JSON that is not a session is the same problem.
    @Test func aBlobOfTheWrongShapeIsAlsoUnreadable() async throws {
        let storage = FakeStorage()
        storage.items["test"] = Data(#"{"cookies":[]}"#.utf8)
        await #expect(throws: CredentialStoreError.unreadable) {
            try await store(storage).currentSession()
        }
    }

    // MARK: - What reaches the Keychain

    @Test func theStoredBlobIsTheSessionAndNothingElse() async throws {
        let storage = FakeStorage()
        try await store(storage).store(session(["COMPASS"]))
        let blob = try #require(storage.items["test"])
        let decoded = try JSONDecoder().decode(StoredSession.self, from: blob)
        #expect(decoded.credential.cookies.map(\.name) == ["COMPASS"])
    }

    @Test("a rotated session written back keeps its domains for the next launch")
    func rotationKeepsDomains() async throws {
        let storage = FakeStorage()
        let scoped = try #require(SessionCookies(cookies: [
            SessionCookies.Cookie(name: "SID", value: "v", domain: ".google.com", path: "/"),
            SessionCookies.Cookie(name: "COMPASS", value: "v", domain: "chat.google.com", path: "/")
        ]))
        try await store(storage).store(StoredSession(credential: scoped, capturedAt: now, expiresAt: nil))
        let rotated = try #require(SessionCookies(cookies: [
            SessionCookies.Cookie(name: "SID", value: "v", domain: ".google.com", path: "/"),
            SessionCookies.Cookie(name: "COMPASS", value: "w", domain: "chat.google.com", path: "/")
        ]))
        try await store(storage).replaceCredential(with: rotated)
        // A fresh store over the same storage: what the next launch reads.
        let read = try #require(try await store(storage).currentSession())
        #expect(read.credential.cookies.map(\.domain) == [".google.com", "chat.google.com"])
        #expect(read.credential["COMPASS"] == "w")
    }
}

/// The one part that talks to the real Keychain, checked at the level it can
/// be: the attributes it asks for.
struct KeychainQueryTests {
    /// A Google session cookie must not ride iCloud Keychain to other devices.
    ///
    /// "The session cookies never leave the Mac" is the architecture's custody
    /// claim and the difference between the E2E tier and the hosted one. A
    /// synchronisable Keychain item would quietly make it false.
    @Test func theItemIsNotSynchronisedToOtherDevices() {
        let query = KeychainSecretStorage.baseQuery(service: "s", account: "a")
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    }

    /// The menu-bar agent reconnects after a reboot without anyone opening a
    /// window, so the credential has to be readable once the machine has been
    /// unlocked - but never before, and never off this device.
    @Test func theItemIsReadableAfterFirstUnlockAndOnlyOnThisDevice() {
        let attributes = KeychainSecretStorage.addAttributes(
            service: "s",
            account: "a",
            data: Data("x".utf8)
        )
        #expect(
            attributes[kSecAttrAccessible as String] as? String
                == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        )
    }

    @Test func theQueryIsForAGenericPasswordUnderTheGivenServiceAndAccount() {
        let query = KeychainSecretStorage.baseQuery(service: "svc", account: "acct")
        #expect(query[kSecClass as String] as? String == (kSecClassGenericPassword as String))
        #expect(query[kSecAttrService as String] as? String == "svc")
        #expect(query[kSecAttrAccount as String] as? String == "acct")
    }

    /// Which keychain this is, made explicit rather than inherited from a
    /// default nobody chose.
    ///
    /// Without `kSecUseDataProtectionKeychain`, macOS uses the legacy
    /// file-based keychain, where `kSecAttrAccessible` is ignored entirely and
    /// item ACLs are bound to the accessing binary's code signature - which is
    /// what produces the "wants to use your confidential information" password
    /// dialog on a signature change. The flag is therefore a custody decision,
    /// exactly like the two beside it, and gets the same treatment: pinned.
    @Test func theQueryNamesWhichKeychainItMeans() {
        let legacy = KeychainSecretStorage.baseQuery(
            service: "s", account: "a", useDataProtection: false
        )
        #expect(legacy[kSecUseDataProtectionKeychain as String] as? Bool == false)

        let modern = KeychainSecretStorage.baseQuery(
            service: "s", account: "a", useDataProtection: true
        )
        #expect(modern[kSecUseDataProtectionKeychain as String] as? Bool == true)
    }

    /// The default must not change silently. Whatever the measurement in
    /// findings.md §19.4 concludes, the value that ships is the one written
    /// here, and changing it is a deliberate edit to a test rather than a
    /// side effect of touching the query builder.
    @Test func theDefaultKeychainIsTheLegacyOneUntilTheMigrationIsMeasured() {
        let query = KeychainSecretStorage.baseQuery(service: "s", account: "a")
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == false)
    }
}
