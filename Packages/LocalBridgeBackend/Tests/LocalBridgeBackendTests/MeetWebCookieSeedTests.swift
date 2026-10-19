import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct MeetWebCookieSeedTests {
    private func selfStatus(_ id: String) throws -> Result<HTTPResponse, any Error> {
        var response = GetSelfUserStatusResponse()
        response.userStatus.userID.id = id
        return try .success(HTTPResponse(
            status: 200, headers: HTTPHeaders([]), body: response.serializedBytes()
        ))
    }

    private func identityTransport(current: String, candidate: String) throws -> ScriptedTransport {
        try ScriptedTransport([
            ScriptedTransport.ok(LocalBridgeBackendTests.shell(app: "DynamiteWebUi")),
            selfStatus(current),
            ScriptedTransport.ok(LocalBridgeBackendTests.shell(app: "DynamiteWebUi")),
            selfStatus(candidate)
        ])
    }

    private final class FakeSecretStorage: SecretStorage, @unchecked Sendable {
        var items: [String: Data] = [:]
        func read(account: String) throws -> Data? {
            items[account]
        }

        func write(_ data: Data, account: String) throws {
            items[account] = data
        }

        func delete(account: String) throws {
            items[account] = nil
        }
    }

    private func captured(_ name: String, domain: String) -> CapturedCookie {
        CapturedCookie(
            name: name, value: "value-for-\(name)", domain: domain, path: "/",
            isSecure: true, isHTTPOnly: true, expiresAt: nil
        )
    }

    private actor Store: CredentialStore {
        var session: StoredSession?

        init(session: StoredSession?) {
            self.session = session
        }

        func currentSession() async throws -> StoredSession? {
            session
        }

        func store(_ session: StoredSession) async throws {
            self.session = session
        }

        func invalidate() async throws {
            session = nil
        }
    }

    @Test func onlyMeetScopedCookiesEnterTheWebView() async throws {
        let cookies = try #require(SessionCookies(cookies: [
            .init(name: "shared", value: "one", domain: ".google.com", path: "/"),
            .init(name: "chatOnly", value: "two", domain: "chat.google.com", path: "/"),
            .init(name: "other", value: "three", domain: "other.example", path: "/")
        ]))
        let session = StoredSession(credential: cookies, capturedAt: .now, expiresAt: nil)
        let result = try await MeetWebCredentials.seeds(from: Store(session: session))
        #expect(result.map(\.name) == ["shared"])
        #expect(result.first?.domain == ".google.com")
    }

    @Test func anExpiredSessionSeedsNothing() async throws {
        let cookies = try #require(SessionCookies(cookies: [
            .init(name: "shared", value: "one", domain: ".google.com", path: "/")
        ]))
        let session = StoredSession(
            credential: cookies, capturedAt: .distantPast, expiresAt: .distantPast
        )
        let result = try await MeetWebCredentials.seeds(from: Store(session: session))
        #expect(result.isEmpty)
    }

    @Test func onlyMeetHostCookiesAreSelectedForSaving() {
        let selected = MeetWebCredentials.meetCookies(from: [
            captured("meet", domain: "meet.google.com"),
            captured("meetDomain", domain: ".meet.google.com"),
            captured("shared", domain: ".google.com"),
            captured("accounts", domain: "accounts.google.com"),
            captured("nearMiss", domain: "notmeet.google.com")
        ])
        #expect(selected.map(\.name) == ["meet", "meetDomain"])
    }

    @Test func savingMeetCookiesPreservesChatAndSurvivesChatRotation() async throws {
        let store = KeychainCredentialStore(storage: FakeSecretStorage(), account: "meet-test")
        let original = try #require(SessionCookies(cookies: [
            .init(name: "SID", value: "chat-original", domain: ".google.com", path: "/"),
            .init(name: "OSID", value: "chat-only", domain: "chat.google.com", path: "/")
        ]))
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.store(StoredSession(credential: original, capturedAt: capturedAt, expiresAt: nil))

        let transport = try identityTransport(current: "same-user", candidate: "same-user")
        let saved = try await MeetWebCredentials.save(captured: [
            captured("SID", domain: ".google.com"),
            captured("OSID", domain: "chat.google.com"),
            captured("MOSID", domain: "meet.google.com"),
            captured("wrong", domain: "accounts.google.com")
        ], to: store, transport: transport)
        #expect(saved == 1)
        let requests = await transport.sent
        #expect(requests.count == 4)
        #expect(requests[0].headers["Cookie"]?.contains("SID=chat-original") == true)
        #expect(requests[2].headers["Cookie"]?.contains("SID=value-for-SID") == true)
        #expect(requests[2].headers["Cookie"]?.contains("OSID=value-for-OSID") == true)
        #expect(requests[2].headers["Cookie"]?.contains("OSID=chat-only") == false)
        #expect(requests[2].headers["Cookie"]?.contains("MOSID=") == false)
        let afterSave = try #require(try await store.currentSession())
        #expect(afterSave.credential.cookies.map(\.name) == ["SID", "OSID", "MOSID"])
        #expect(afterSave.credential["SID"] == "chat-original")
        #expect(afterSave.capturedAt == capturedAt)

        let rotatedChat = try #require(SessionCookies(cookies: [
            .init(name: "SID", value: "rotated", domain: ".google.com", path: "/"),
            .init(name: "OSID", value: "chat-only", domain: "chat.google.com", path: "/")
        ]))
        try await store.replaceCredential(with: rotatedChat)
        let afterRotation = try #require(try await store.currentSession())
        #expect(afterRotation.credential.cookies.map(\.name) == ["SID", "OSID", "MOSID"])
        #expect(afterRotation.credential["SID"] == "rotated")
        #expect(afterRotation.capturedAt == capturedAt)

        try await store.store(StoredSession(credential: rotatedChat, capturedAt: .now, expiresAt: nil))
        #expect(try await store.currentSession()?.credential.cookies.map(\.name) == ["SID", "OSID"])
    }

    @Test func absentChatSessionCannotBeCreatedByMeetCapture() async throws {
        let store = KeychainCredentialStore(storage: FakeSecretStorage(), account: "empty-meet-test")
        #expect(try await MeetWebCredentials.save(captured: [
            captured("SID", domain: ".google.com"),
            captured("MOSID", domain: "meet.google.com")
        ], to: store) == 0)
        #expect(try await store.currentSession() == nil)
    }

    @Test func differentAccountCannotBeSaved() async throws {
        let store = KeychainCredentialStore(storage: FakeSecretStorage(), account: "changed-meet-test")
        let chat = try #require(SessionCookies(cookies: [
            .init(name: "SID", value: "chat-account", domain: ".google.com", path: "/")
        ]))
        try await store.store(StoredSession(credential: chat, capturedAt: .now, expiresAt: nil))
        await #expect(throws: MeetWebCaptureError.accountMismatch) {
            try await MeetWebCredentials.save(captured: [
                captured("SID", domain: ".google.com"),
                captured("MOSID", domain: "meet.google.com")
            ], to: store, transport: identityTransport(current: "chat-user", candidate: "meet-user"))
        }
        #expect(try await store.currentSession()?.credential.cookies.map(\.name) == ["SID"])
    }

    @Test func capturedCookiesThatCannotSignIntoChatAreNotSaved() async throws {
        let store = KeychainCredentialStore(storage: FakeSecretStorage(), account: "unverified-meet-test")
        let chat = try #require(SessionCookies(cookies: [
            .init(name: "SID", value: "chat-account", domain: ".google.com", path: "/")
        ]))
        try await store.store(StoredSession(credential: chat, capturedAt: .now, expiresAt: nil))
        let transport = try ScriptedTransport([
            ScriptedTransport.ok(LocalBridgeBackendTests.shell(app: "DynamiteWebUi")),
            selfStatus("chat-user"),
            ScriptedTransport.ok(LocalBridgeBackendTests.shell(app: "AccountsSignInUi"))
        ])
        await #expect(throws: MeetWebCaptureError.accountVerificationFailed(
            source: .capturedBrowser, issue: .signedOut
        )) {
            try await MeetWebCredentials.save(captured: [
                captured("SID", domain: ".google.com"),
                captured("MOSID", domain: "meet.google.com")
            ], to: store, transport: transport)
        }
        #expect(try await store.currentSession()?.credential.cookies.map(\.name) == ["SID"])
    }

    @Test func missingCapturedChatCookiesCannotBeVerified() async throws {
        let store = KeychainCredentialStore(storage: FakeSecretStorage(), account: "no-sid-test")
        let chat = try #require(SessionCookies(cookies: [
            .init(name: "SID", value: "chat-account", domain: ".google.com", path: "/")
        ]))
        try await store.store(StoredSession(credential: chat, capturedAt: .now, expiresAt: nil))
        await #expect(throws: MeetWebCaptureError.accountVerificationFailed(
            source: .capturedBrowser, issue: .missingCookies
        )) {
            try await MeetWebCredentials.save(captured: [
                captured("MOSID", domain: "meet.google.com")
            ], to: store)
        }
        #expect(try await store.currentSession()?.credential.cookies.map(\.name) == ["SID"])
    }

    @Test func verificationIdentifiesTheFailingSourceWithoutExposingURLs() async throws {
        let store = KeychainCredentialStore(storage: FakeSecretStorage(), account: "redirect-meet-test")
        let chat = try #require(SessionCookies(cookies: [
            .init(name: "SID", value: "chat-account", domain: ".google.com", path: "/")
        ]))
        try await store.store(StoredSession(credential: chat, capturedAt: .now, expiresAt: nil))
        let url = try #require(URL(string: "https://accounts.google.com/signin?token=private-sentinel"))
        let transport = ScriptedTransport([ScriptedTransport.ok("sign-in", url: url)])
        let expected = MeetWebCaptureError.accountVerificationFailed(
            source: .storedChat, issue: .signInRedirect
        )
        await #expect(throws: expected) {
            try await MeetWebCredentials.save(captured: [
                captured("SID", domain: ".google.com"),
                captured("MOSID", domain: "meet.google.com")
            ], to: store, transport: transport)
        }
        #expect(expected.verificationDescription == "Stored Chat: Chat redirected to Google sign-in.")
        #expect(expected.verificationDescription?.contains("private-sentinel") == false)
    }

    @Test func aChangedStoredSessionCannotReceiveTheVerifiedMeetCookies() async throws {
        let store = KeychainCredentialStore(storage: FakeSecretStorage(), account: "race-meet-test")
        let cookies = try #require(SessionCookies(cookies: [
            .init(name: "SID", value: "original", domain: ".google.com", path: "/")
        ]))
        let original = StoredSession(credential: cookies, capturedAt: .distantPast, expiresAt: nil)
        try await store.store(original)
        let capture = try #require(try await store.snapshot())
        try await store.store(StoredSession(credential: cookies, capturedAt: .now, expiresAt: nil))
        await #expect(throws: MeetWebCaptureError.sessionChangedDuringVerification) {
            try await store.mergeMeetCookies([
                .init(name: "MOSID", value: "meet", domain: "meet.google.com", path: "/")
            ], expected: capture)
        }
        #expect(try await store.currentSession()?.credential.cookies.map(\.name) == ["SID"])
    }

    @Test func aCookieRotationDuringVerificationKeepsTheNewestChatCookiesAndSavesMeet() async throws {
        let storage = FakeSecretStorage()
        let store = KeychainCredentialStore(storage: storage, account: "rotation-meet-test")
        let originalCookies = try #require(SessionCookies(cookies: [
            .init(name: "SID", value: "original", domain: ".google.com", path: "/"),
            .init(name: "OSID", value: "chat", domain: "chat.google.com", path: "/")
        ]))
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let original = StoredSession(credential: originalCookies, capturedAt: capturedAt, expiresAt: nil)
        try await store.store(original)
        let capture = try #require(try await store.snapshot())
        let rotated = try #require(SessionCookies(cookies: [
            .init(name: "SID", value: "refreshed", domain: ".google.com", path: "/"),
            .init(name: "OSID", value: "chat", domain: "chat.google.com", path: "/")
        ]))
        // A second instance models the running Chat connection writing back
        // while the temporary sign-in view is checking the account.
        try await KeychainCredentialStore(storage: storage, account: "rotation-meet-test")
            .replaceCredential(with: rotated)
        #expect(try await store.mergeMeetCookies([
            .init(name: "MOSID", value: "meet", domain: "meet.google.com", path: "/")
        ], expected: capture))
        let saved = try #require(try await store.currentSession())
        #expect(saved.credential["SID"] == "refreshed")
        #expect(saved.credential.cookies.map(\.name) == ["SID", "OSID", "MOSID"])
        #expect(saved.capturedAt == capturedAt)
    }
}

extension MeetWebCookieSeedTests {
    @Test(arguments: [false, true])
    func anotherSameAccountLoginBeforeVerificationCannotAdoptOldBrowserCookies(
        changesExpiry: Bool
    ) async throws {
        let store = KeychainCredentialStore(storage: FakeSecretStorage(), account: "pinned-meet-test")
        let capture = CookieCapture(
            cookies: [captured("SID", domain: ".google.com")],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pageURL: "https://chat.google.com/", pageTitle: "Google Chat"
        )
        #expect(try await capture.save(to: store))
        let original = try #require(try await store.currentSession())
        let replacement = StoredSession(
            credential: original.credential,
            capturedAt: changesExpiry ? original.capturedAt : original.capturedAt.addingTimeInterval(1),
            expiresAt: changesExpiry ? original.capturedAt.addingTimeInterval(9 * 86400) : nil
        )
        try await store.store(replacement)
        let transport = try identityTransport(current: "same-user", candidate: "same-user")
        await #expect(throws: MeetWebCaptureError.sessionChangedDuringVerification) {
            try await MeetWebCredentials.save(captured: [
                captured("SID", domain: ".google.com"), captured("MOSID", domain: "meet.google.com")
            ], to: store, expectedCapture: capture, transport: transport)
        }
        #expect(await transport.sent.isEmpty)
        #expect(try await store.currentSession() == replacement)
    }

    @Test func thePinnedLoginCanRotateAndStillMergeOnlyFreshMeetCookies() async throws {
        let store = KeychainCredentialStore(storage: FakeSecretStorage(), account: "pinned-rotated-meet-test")
        let capture = CookieCapture(
            cookies: [captured("SID", domain: ".google.com")],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pageURL: "https://chat.google.com/", pageTitle: "Google Chat"
        )
        #expect(try await capture.save(to: store))
        let rotated = try #require(SessionCookies(cookies: [
            .init(name: "SID", value: "current-chat", domain: ".google.com", path: "/")
        ]))
        try await store.replaceCredential(with: rotated)
        let transport = try identityTransport(current: "same-user", candidate: "same-user")
        #expect(try await MeetWebCredentials.save(captured: [
            captured("SID", domain: ".google.com"), captured("MOSID", domain: "meet.google.com")
        ], to: store, expectedCapture: capture, transport: transport) == 1)
        let stored = try #require(try await store.currentSession())
        #expect(stored.credential["SID"] == "current-chat")
        #expect(stored.credential.cookies.map(\.name) == ["SID", "MOSID"])
        #expect(stored.capturedAt == capture.report.capturedAt)
        #expect(await transport.sent.count == 4)
    }
}
