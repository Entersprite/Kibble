import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct SessionCustodyTests {
    private final class Secrets: SecretStorage, @unchecked Sendable {
        private let lock = NSLock()
        private var data: [String: Data] = [:]
        func read(account: String) -> Data? {
            lock.withLock { data[account] }
        }

        func write(_ value: Data, account: String) {
            lock.withLock { data[account] = value }
        }

        func delete(account: String) {
            lock.withLock { data[account] = nil }
        }
    }

    private func session(_ value: String = "initial") throws -> StoredSession {
        try StoredSession(
            credential: #require(SessionCookies(header: "SID=\(value)")),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000), expiresAt: nil
        )
    }

    private func transport() throws -> ScriptedTransport {
        var response = GetSelfUserStatusResponse()
        response.userStatus.userID.id = "verified-self"
        return try ScriptedTransport([
            ScriptedTransport.ok(LocalBridgeBackendTests.shell(app: "DynamiteWebUi")),
            .success(HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes()))
        ])
    }

    @Test func identicalCaptureDatesDoNotLetOldRotationsOrMeetMergeReachANewLogin() async throws {
        let store = KeychainCredentialStore(storage: Secrets(), account: "capture")
        try await store.store(session())
        let prior = try #require(try await store.snapshot())
        try await store.store(session("replacement"))
        try await store.replaceCredential(
            with: #require(SessionCookies(header: "SID=stale")),
            belongingTo: prior
        )
        #expect(try await store.currentSession()?.credential["SID"] == "replacement")
        await #expect(throws: MeetWebCaptureError.sessionChangedDuringVerification) {
            try await store.mergeMeetCookies([
                .init(name: "MOSID", value: "meet", domain: "meet.google.com", path: "/")
            ], expected: prior)
        }
    }

    @Test func verificationInstallsInAnotherSlotAndCookieRotationKeepsItsGeneration() async throws {
        let secrets = Secrets()
        let staging = KeychainCredentialStore(storage: secrets, account: "staging")
        try await staging.store(session())
        let verified = try await staging.verify(transport: transport())
        #expect(verified.selfID.rawValue == "verified-self")
        try await staging.replaceCredential(with: #require(SessionCookies(header: "SID=rotated")))
        let destination = KeychainCredentialStore(storage: secrets, account: "account/generation")
        try await destination.install(verified, generation: "generation")
        try await destination.install(verified, generation: "generation")
        let bound = KeychainCredentialStore(
            storage: secrets,
            account: "account/generation",
            expectedGeneration: "generation"
        )
        let capture = try #require(try await bound.snapshot())
        #expect(try await bound.installedIdentity()?.rawValue == "verified-self")
        #expect(capture.session.credential["SID"] == "rotated")
        try await bound.replaceCredential(
            with: #require(SessionCookies(header: "SID=next")),
            belongingTo: capture
        )
        #expect(try await bound.snapshot()?.generation == "generation")
        #expect(try await staging.currentSession()?.credential["SID"] == "rotated")
    }

    @Test func changedCaptureCannotInstallAndOccupiedSlotCannotBeReplaced() async throws {
        let secrets = Secrets()
        let staging = KeychainCredentialStore(storage: secrets, account: "staging")
        let destination = KeychainCredentialStore(storage: secrets, account: "destination")
        try await staging.store(session())
        let verified = try await staging.verify(transport: transport())
        try await destination.store(session("occupied"))
        await #expect(throws: SessionCustodyError.occupied) {
            try await destination.install(verified, generation: "fresh")
        }
        try await staging.store(session("replacement"))
        let empty = KeychainCredentialStore(storage: secrets, account: "empty")
        await #expect(throws: SessionCustodyError.sessionChanged) {
            try await empty.install(verified, generation: "fresh")
        }
        #expect(try await empty.currentSession() == nil)
        #expect(try await destination.currentSession()?.credential["SID"] == "occupied")
    }

    @Test func boundRuntimeCannotReadWriteOrEraseAnotherGeneration() async throws {
        let secrets = Secrets()
        let store = KeychainCredentialStore(storage: secrets, account: "slot")
        try await store.store(session())
        let capture = try #require(try await store.snapshot())
        let bound = KeychainCredentialStore(
            storage: secrets,
            account: "slot",
            expectedGeneration: capture.generation
        )
        try await store.store(session("replacement"))
        await #expect(throws: SessionCustodyError.sessionChanged) { try await bound.currentSession() }
        await #expect(throws: SessionCustodyError.sessionChanged) { try await bound.store(session()) }
        await #expect(throws: SessionCustodyError.sessionChanged) { try await bound.invalidate() }
        #expect(try await store.currentSession()?.credential["SID"] == "replacement")
    }

    @Test func legacyBlobCanBeVerifiedAndAdoptedWithoutChangingTheOriginal() async throws {
        let secrets = Secrets()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let original = try encoder.encode(session())
        secrets.write(original, account: "primary")
        let legacy = KeychainCredentialStore(storage: secrets, account: "primary")
        let verified = try await legacy.verify(transport: transport())
        let destination = KeychainCredentialStore(storage: secrets, account: "new-account/generation")
        try await destination.install(verified, generation: "generation")
        #expect(secrets.read(account: "primary") == original)
        #expect(try await destination.currentSession() == legacy.currentSession())
    }
}
