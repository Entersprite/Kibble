import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The path from a login capture to a running bridge, with no core type crossing
/// into the app.
///
/// The app may not import `GChatBridgeCore` — `test.sh` enforces it, because a
/// future iOS binary carrying no reverse-engineered code is the architecture's
/// whole distribution argument. So everything the app needs is spelled here in
/// types this package owns, and these are the tests for that facade.
struct SessionHandoffTests {
    private let now = Date(timeIntervalSince1970: 1_788_166_800)

    private final class FakeStorage: SecretStorage, @unchecked Sendable {
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

    private func store() -> KeychainCredentialStore {
        KeychainCredentialStore(storage: FakeStorage(), account: "test")
    }

    private func capture(_ cookies: [CapturedCookie]) -> CookieCapture {
        CookieCapture(
            cookies: cookies,
            capturedAt: now,
            pageURL: "https://chat.google.com/app/home",
            pageTitle: "Google Chat"
        )
    }

    private func cookie(
        _ name: String,
        domain: String = "chat.google.com",
        expiresAt: Date? = nil
    ) -> CapturedCookie {
        CapturedCookie(
            name: name,
            value: "value-for-\(name)",
            domain: domain,
            path: "/",
            isSecure: true,
            isHTTPOnly: true,
            expiresAt: expiresAt
        )
    }

    // MARK: - Saving a capture

    @Test func savingACaptureStoresItsCredential() async throws {
        let store = store()
        let saved = try await capture([cookie("COMPASS"), cookie("OSID")]).save(to: store)
        #expect(saved)
        let summary = try await store.summary(at: now)
        #expect(summary?.cookieCount == 2)
    }

    @Test func savingACaptureWithNothingInScopeStoresNothing() async throws {
        let store = store()
        let saved = try await capture([cookie("LSID", domain: "accounts.google.com")]).save(to: store)
        #expect(!saved)
        #expect(try await store.summary(at: now) == nil)
    }

    /// A capture that fails must not silently leave the previous session in
    /// place looking like the new one.
    @Test func savingReplacesAnEarlierSession() async throws {
        let store = store()
        _ = try await capture([cookie("OLD")]).save(to: store)
        _ = try await capture([cookie("NEW1"), cookie("NEW2")]).save(to: store)
        #expect(try await store.summary(at: now)?.cookieCount == 2)
    }

    // MARK: - What the app can say about the session

    @Test func thereIsNoSummaryWhenNothingIsStored() async throws {
        #expect(try await store().summary(at: now) == nil)
    }

    @Test func theSummaryCarriesTheDeadlineWithoutCarryingTheCredential() async throws {
        let store = store()
        _ = try await capture([
            cookie("COMPASS", expiresAt: now.addingTimeInterval(9 * 86400)),
            cookie("OSID", expiresAt: now.addingTimeInterval(399 * 86400))
        ]).save(to: store)

        let summary = try #require(try await store.summary(at: now))
        #expect(summary.cookieCount == 2)
        #expect(summary.expiresAt == now.addingTimeInterval(9 * 86400))
        #expect(!summary.isExpired)
        #expect(!summary.description.contains("value-for-COMPASS"))
    }

    @Test func anExpiredSessionSaysSo() async throws {
        let store = store()
        _ = try await capture([cookie("COMPASS", expiresAt: now.addingTimeInterval(-1))])
            .save(to: store)
        #expect(try await store.summary(at: now)?.isExpired == true)
    }

    /// Nine days is the real figure for `COMPASS`, and it is what decides how
    /// often somebody has to sign in again — so it belongs where they can read it.
    @Test func theSummarySaysHowLongIsLeftInDays() async throws {
        let store = store()
        _ = try await capture([cookie("COMPASS", expiresAt: now.addingTimeInterval(9 * 86400))])
            .save(to: store)
        let summary = try #require(try await store.summary(at: now))
        #expect(summary.description.contains("9 days"))
    }

    @Test func aSessionWithNoStatedExpirySaysThatRatherThanGuessing() async throws {
        let store = store()
        _ = try await capture([cookie("COMPASS")]).save(to: store)
        let summary = try #require(try await store.summary(at: now))
        #expect(summary.expiresAt == nil)
        #expect(!summary.isExpired)
    }

    // MARK: - Building the bridge

    @Test func thereIsNoBridgeWithoutAStoredSession() async throws {
        #expect(try await LocalBridgeBackend.using(store()) == nil)
    }

    @Test func aStoredSessionProducesABridge() async throws {
        let store = store()
        _ = try await capture([cookie("COMPASS"), cookie("OSID")]).save(to: store)
        #expect(try await LocalBridgeBackend.using(store) != nil)
    }

    /// An expired session still builds a bridge.
    ///
    /// Expiry is a lower bound on trouble, never a verdict: a credential can be
    /// revoked inside every stated expiry, and one past its expiry can still be
    /// accepted. Refusing to try would turn a guess into a policy, and the
    /// request that settles it costs one round trip.
    @Test func anExpiredSessionIsStillWorthTrying() async throws {
        let store = store()
        _ = try await capture([cookie("COMPASS", expiresAt: now.addingTimeInterval(-86400))])
            .save(to: store)
        #expect(try await LocalBridgeBackend.using(store) != nil)
    }
}

/// Closing the loop: a cookie rotated on the live channel has to reach the
/// Keychain, or the next launch replays a credential that went stale on the
/// first poll of the last one.
struct RotationWriteBackTests {
    private final class FakeStorage: SecretStorage, @unchecked Sendable {
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

    private func storedSession(_ store: KeychainCredentialStore) async throws -> StoredSession? {
        try await store.currentSession()
    }

    @Test func aRotationOnTheChannelIsPersisted() async throws {
        let store = KeychainCredentialStore(storage: FakeStorage(), account: "test")
        let capture = CookieCapture(
            cookies: [
                CapturedCookie(
                    name: "COMPASS",
                    value: "old",
                    domain: "chat.google.com",
                    path: "/",
                    isSecure: true,
                    isHTTPOnly: true,
                    expiresAt: nil
                )
            ],
            capturedAt: Date(timeIntervalSince1970: 1_788_166_800),
            pageURL: "https://chat.google.com/app/home",
            pageTitle: "Chat"
        )
        _ = try await capture.save(to: store)

        let transport = ScriptedTransport(
            [
                ScriptedTransport.ok(LocalBridgeBackendTests.shell(app: "DynamiteWebUi")),
                .success(HTTPResponse(
                    status: 200,
                    headers: HTTPHeaders([("Set-Cookie", "COMPASS=grown; Path=/")]),
                    body: Data()
                )),
                ScriptedTransport.ok("")
            ],
            streams: [
                ScriptedTransport.Script(
                    headers: HTTPHeaders([
                        ("X-HTTP-Initial-Response", #"[[0,["c","S3ss10n","",8,12,30000]]]"#)
                    ]),
                    chunks: []
                )
            ]
        )
        // `retry: .immediate` because this test waits for the channel to
        // finish, and the scripted transport always runs out - so on the
        // default policy it would sleep out the whole reconnect ladder
        // (0.5 + 1 + 2 + 4 real seconds) to assert something about cookies.
        let backend = try #require(
            await LocalBridgeBackend.using(store, transport: transport, retry: .immediate)
        )
        try await backend.connect()
        await backend.waitForChannel()

        #expect(try await storedSession(store)?.credential["COMPASS"] == "grown")
    }

    /// The rewritten session keeps its capture date. Treating a rotation as a
    /// fresh login would reset the age of a credential that is no younger.
    @Test func aRotationDoesNotPretendTheSessionWasJustCaptured() async throws {
        let store = KeychainCredentialStore(storage: FakeStorage(), account: "test")
        let captured = Date(timeIntervalSince1970: 1_788_166_800)
        let original = try StoredSession(
            credential: #require(SessionCookies(header: "COMPASS=old")),
            capturedAt: captured,
            expiresAt: captured.addingTimeInterval(9 * 86400)
        )
        try await store.store(original)

        let transport = ScriptedTransport(
            [
                ScriptedTransport.ok(LocalBridgeBackendTests.shell(app: "DynamiteWebUi")),
                .success(HTTPResponse(
                    status: 200,
                    headers: HTTPHeaders([("Set-Cookie", "COMPASS=grown; Path=/")]),
                    body: Data()
                )),
                ScriptedTransport.ok("")
            ],
            streams: [
                ScriptedTransport.Script(
                    headers: HTTPHeaders([
                        ("X-HTTP-Initial-Response", #"[[0,["c","S3ss10n","",8,12,30000]]]"#)
                    ]),
                    chunks: []
                )
            ]
        )
        // `retry: .immediate` because this test waits for the channel to
        // finish, and the scripted transport always runs out - so on the
        // default policy it would sleep out the whole reconnect ladder
        // (0.5 + 1 + 2 + 4 real seconds) to assert something about cookies.
        let backend = try #require(
            await LocalBridgeBackend.using(store, transport: transport, retry: .immediate)
        )
        try await backend.connect()
        await backend.waitForChannel()

        let reloaded = try await storedSession(store)
        #expect(reloaded?.capturedAt == captured)
        #expect(reloaded?.expiresAt == captured.addingTimeInterval(9 * 86400))
    }
}
