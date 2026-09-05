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

    /// `reachability: nil` on every test in this section but the last one,
    /// deliberately: `using(_:transport:)`'s real default is a live
    /// `NWPathReachabilityMonitor`, and CLAUDE.md's testing rule is that a
    /// test must not need network and must inject a fake. A default argument
    /// is still evaluated at the call site even when the function returns
    /// before touching it, so leaving this out here would start a real
    /// `NWPathMonitor` for no reason. `theRealUsingOverloadSuppliesA
    /// RealReachabilityMonitor` below is the one place that default is
    /// exercised on purpose, because it exists to assert what the default
    /// *is* - see its own doc comment for how that stays consistent with this
    /// one.
    @Test func thereIsNoBridgeWithoutAStoredSession() async throws {
        #expect(try await LocalBridgeBackend.using(store(), reachability: nil) == nil)
    }

    @Test func aStoredSessionProducesABridge() async throws {
        let store = store()
        _ = try await capture([cookie("COMPASS"), cookie("OSID")]).save(to: store)
        #expect(try await LocalBridgeBackend.using(store, reachability: nil) != nil)
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
        #expect(try await LocalBridgeBackend.using(store, reachability: nil) != nil)
    }

    /// The one test in this file that must **not** pass `reachability: nil` -
    /// every test above does, to keep this package's unit suite off a real
    /// network monitor. This one exists to assert what `using(_:transport:)`'s
    /// *default* actually is, because `SystemLaunchServices.swift:67` calls it
    /// with nothing extra and relies on exactly this default for the whole
    /// reachability feature to reach production. `channelReachability` is
    /// internal rather than `private` for the same reason: a `private`
    /// property would make this assertion impossible even through `@testable
    /// import`, and a future edit reverting the default to `nil` would then
    /// compile clean and pass every other test in this suite while the
    /// feature went silently inert.
    @Test func theRealUsingOverloadSuppliesARealReachabilityMonitor() async throws {
        let store = store()
        _ = try await capture([cookie("COMPASS"), cookie("OSID")]).save(to: store)
        let backend = try #require(await LocalBridgeBackend.using(store))
        #expect(await backend.channelReachability != nil)
    }

    /// `tracingChannelTo` is `nil` on every call in this file but this one -
    /// diagnostic instrumentation for `findings.md` §12.4, and opt-in the same
    /// way `reachability` above is, except this one never has a "real" default
    /// to fall back to: nothing in this repo enables it unless
    /// `SystemLaunchServices.makeSession()` saw `--probe=channeltrace`. This
    /// only proves the parameter exists and does not stop a bridge from being
    /// built - the file it would write to is a scratch path under the
    /// system's own temporary directory, never anywhere this suite could
    /// leave litter behind or that could be mistaken for a repo file.
    @Test func aTracingURLStillProducesAWorkingBridge() async throws {
        let store = store()
        _ = try await capture([cookie("COMPASS"), cookie("OSID")]).save(to: store)
        let traceFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("gchat-channel-trace-test-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: traceFile) }
        #expect(try await LocalBridgeBackend.using(
            store,
            reachability: nil,
            tracingChannelTo: traceFile
        ) != nil)
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

    /// `retry: .immediate` because this test waits for the channel to
    /// finish, and the scripted transport always runs out - so on the
    /// default policy it would sleep out the whole reconnect ladder before
    /// asserting something about cookies.
    ///
    /// Was a single stream, ending cleanly with no chunks, and two non-shell
    /// responses (register, ack). Since task 3 of the reconnect taxonomy a
    /// transport failure never gives up on its own: the reopen this test
    /// used to let exhaust the fake (and stop, via the old four-attempt
    /// bound) would now retry forever, and `waitForChannel()` below would
    /// hang. The second stream scripts a deliberate terminal status for that
    /// reopen instead, once the rotation this test is about has already been
    /// absorbed; a third and fourth response cover `connect()`'s concurrent
    /// `resolveAndEmitSelf()` and (Part 1's addition) the initial ping, which
    /// both race the channel's own register/ack for the same queue and -
    /// with too few responses for those four callers - could otherwise steal
    /// one and send the channel's own register or ack into the same
    /// now-unbounded retry, which with `retry: .immediate` is a zero-wait
    /// busy loop, not merely a slow one - see `LiveChannelRotationTests`'s
    /// own comment for what that actually did to this suite.
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
                ScriptedTransport.ok(""),
                ScriptedTransport.ok(""),
                ScriptedTransport.ok("")
            ],
            streams: [
                ScriptedTransport.Script(
                    headers: HTTPHeaders([
                        ("X-HTTP-Initial-Response", #"[[0,["c","S3ss10n","",8,12,30000]]]"#)
                    ]),
                    chunks: []
                ),
                ScriptedTransport.Script(status: 403, chunks: [])
            ]
        )
        let backend = try #require(
            await LocalBridgeBackend.using(store, transport: transport, retry: .immediate)
        )
        try await backend.connect()
        await backend.waitForChannel()

        #expect(try await storedSession(store)?.credential["COMPASS"] == "grown")
    }

    /// The rewritten session keeps its capture date. Treating a rotation as a
    /// fresh login would reset the age of a credential that is no younger.
    ///
    /// `retry: .immediate` because this test waits for the channel to
    /// finish, and the scripted transport always runs out - so on the
    /// default policy it would sleep out the whole reconnect ladder before
    /// asserting something about cookies. Same fix as
    /// `aRotationOnTheChannelIsPersisted` above and for the same reason: a
    /// second, deliberately terminal stream so the reopen (now unbounded
    /// since task 3 of the reconnect taxonomy) still ends the channel
    /// cleanly, and a fourth and fifth response so `resolveAndEmitSelf()`
    /// and (Part 1's addition) the initial ping, both racing the channel's
    /// own register/ack, cannot send one of those into that same unbounded,
    /// zero-wait retry - see `LiveChannelRotationTests`'s own comment for
    /// what that actually did to this suite.
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
                ScriptedTransport.ok(""),
                ScriptedTransport.ok(""),
                ScriptedTransport.ok("")
            ],
            streams: [
                ScriptedTransport.Script(
                    headers: HTTPHeaders([
                        ("X-HTTP-Initial-Response", #"[[0,["c","S3ss10n","",8,12,30000]]]"#)
                    ]),
                    chunks: []
                ),
                ScriptedTransport.Script(status: 403, chunks: [])
            ]
        )
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
