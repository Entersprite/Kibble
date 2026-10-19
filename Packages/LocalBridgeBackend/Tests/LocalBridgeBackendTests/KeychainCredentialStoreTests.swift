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

        var deleteError: (any Error)?

        func delete(account: String) throws {
            if let deleteError {
                throw deleteError
            }
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

    private func migrating(_ current: FakeStorage, from legacy: FakeStorage) -> KeychainCredentialStore {
        KeychainCredentialStore(storage: current, legacyStorage: legacy, account: "test")
    }

    // MARK: - The session saved before the rename (spec §3)

    @Test func theServicesAreKibblesAndTheOldOneIsGChats() {
        #expect(KeychainCredentialStore.defaultService == "com.entersprite.kibble.session")
        #expect(KeychainCredentialStore.legacyService == "com.entersprite.gchat.session")
    }

    @Test func aSessionUnderTheOldServiceMovesToTheNewOne() async throws {
        let current = FakeStorage()
        let legacy = FakeStorage()
        let original = session(["COMPASS", "OSID"])
        try await store(legacy).store(original)
        #expect(try await migrating(current, from: legacy).currentSession() == original)
        #expect(current.items["test"] != nil)
        #expect(legacy.items["test"] == nil)
    }

    @Test func theNewServiceWinsAndTheOldOneIsNotRead() async throws {
        let current = FakeStorage()
        let legacy = FakeStorage()
        try await store(current).store(session(["NEW"]))
        legacy.readError = Boom()
        let loaded = try await migrating(current, from: legacy).currentSession()
        #expect(loaded?.credential.cookies.map(\.name) == ["NEW"])
    }

    /// CLAUDE.md: "no credential" never means "could not look".
    @Test func aRefusedReadOfTheOldServiceIsReportedAndLeavesIt() async throws {
        let current = FakeStorage()
        let legacy = FakeStorage()
        try await store(legacy).store(session())
        legacy.readError = Boom()
        await #expect(throws: (any Error).self) {
            try await migrating(current, from: legacy).currentSession()
        }
        #expect(legacy.items["test"] != nil)
        #expect(current.items.isEmpty)
    }

    @Test func aFailedWriteLeavesTheOldSessionWhereItWas() async throws {
        let current = FakeStorage()
        let legacy = FakeStorage()
        try await store(legacy).store(session())
        current.writeError = Boom()
        await #expect(throws: (any Error).self) {
            try await migrating(current, from: legacy).currentSession()
        }
        #expect(legacy.items["test"] != nil)
    }

    @Test func anUnreadableOldBlobIsReportedAndNotMoved() async throws {
        let current = FakeStorage()
        let legacy = FakeStorage()
        legacy.items["test"] = Data("not a session".utf8)
        await #expect(throws: (any Error).self) {
            try await migrating(current, from: legacy).currentSession()
        }
        #expect(current.items.isEmpty)
        #expect(legacy.items["test"] != nil)
    }

    @Test func aRefusedDeleteOfTheOldServiceStillSignsIn() async throws {
        let current = FakeStorage()
        let legacy = FakeStorage()
        let original = session()
        try await store(legacy).store(original)
        legacy.deleteError = Boom()
        #expect(try await migrating(current, from: legacy).currentSession() == original)
        #expect(current.items["test"] != nil)
    }

    /// Review Focus 1: without this, a refused delete would let the next
    /// launch's migration bring back a session the person signed out of.
    @Test func signingOutAlsoRemovesTheOldService() async throws {
        let current = FakeStorage()
        let legacy = FakeStorage()
        try await store(current).store(session(["NEW"]))
        try await store(legacy).store(session(["OLD"]))
        let subject = migrating(current, from: legacy)
        try await subject.invalidate()
        #expect(legacy.items.isEmpty)
        #expect(try await subject.currentSession() == nil)
    }

    @Test func aRefusedDeleteOfTheOldServiceFailsTheSignOut() async throws {
        let current = FakeStorage()
        let legacy = FakeStorage()
        try await store(current).store(session(["NEW"]))
        try await store(legacy).store(session(["OLD"]))
        legacy.deleteError = Boom()
        await #expect(throws: (any Error).self) {
            try await migrating(current, from: legacy).invalidate()
        }
        // The old service goes first: had the new one gone already, the next
        // launch would migrate the signed-out session back.
        #expect(current.items["test"] != nil)
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
