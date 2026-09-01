import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The `/api/` probe run against the Keychain credential, rather than a
/// hand-pasted header the way `gchat-probe --api` needs one.
///
/// Every path here is exercised with `ScriptedTransport`, never a network or a
/// real Keychain - the repo's testing rule - and the two leak tests exist
/// because this report is the one piece of output a human pastes verbatim into
/// `findings.md`: a cookie value or an xsrf token in it would be a credential
/// checked into git.
@Suite("APIProbeReport")
struct APIProbeReportTests {
    private struct Boom: Error {}

    /// A transport-level error carrying a payload distinctive enough that its
    /// presence in a report is unambiguously a leak. `CustomStringConvertible`
    /// so `\(error)` and `String(describing: error)` - what a raw, unguarded
    /// catch site actually calls - produce `description` exactly, the same
    /// way a real `URLError` or any other transport failure would.
    private struct SentinelError: Error, CustomStringConvertible {
        let description: String
    }

    /// A `SecretStorage` that lives in memory and can be told to fail.
    ///
    /// `KeychainCredentialStoreTests.FakeStorage` is `private` to that file and
    /// therefore unreachable here, so this is a second, minimal copy rather than
    /// a widened import - matching the shape that file already established.
    private final class FakeSecretStorage: SecretStorage, @unchecked Sendable {
        var items: [String: Data] = [:]
        var readError: (any Error)?

        func read(account: String) throws -> Data? {
            if let readError {
                throw readError
            }
            return items[account]
        }

        func write(_ data: Data, account: String) throws {
            items[account] = data
        }

        func delete(account: String) throws {
            items[account] = nil
        }
    }

    private func store(_ storage: FakeSecretStorage) -> KeychainCredentialStore {
        KeychainCredentialStore(storage: storage, account: "probe-test")
    }

    /// A session carrying a cookie value distinctive enough that its presence
    /// in a report is unambiguously a leak, not a coincidence.
    private func storedSession() -> StoredSession {
        StoredSession(
            credential: SessionCookies(cookies: [
                SessionCookies.Cookie(name: "SID", value: "SECRET-COOKIE-VALUE-DO-NOT-LEAK")
            ])!,
            capturedAt: .now,
            expiresAt: nil
        )
    }

    /// The `WIZ_global_data` shell `Bootstrap` reads, in the shape
    /// `BootstrapTests.shell(app:)` established. `SMqcke` is a token distinctive
    /// enough to check its absence from a report the same way the cookie value is.
    private func shell(app: String, xsrfToken: String = "XSRF-TOKEN-SECRET-VALUE") -> HTTPResponse {
        let html = """
        <script nonce="x">window.WIZ_global_data = {"qwAQke":"\(app)",\
        "SMqcke":"\(xsrfToken)","cfb2h":"boq_x"};</script>
        """
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(html.utf8))
    }

    private func selfStatusResponse(userID: String = "user-1") throws -> HTTPResponse {
        var response = GetSelfUserStatusResponse()
        var status = UserStatus()
        var identifier = UserId()
        identifier.id = userID
        status.userID = identifier
        response.userStatus = status
        return try HTTPResponse(
            status: 200,
            headers: HTTPHeaders([]),
            body: response.serializedBytes()
        )
    }

    /// Field 11 only - §3.6's control shape, and what every rung's control
    /// response is expected to look like.
    private func controlWorldResponse() -> HTTPResponse {
        HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data([0x58, 0x15]))
    }

    /// The control's field 11, plus a field the control never carries - what a
    /// rung that actually answers with more than the control looks like on the
    /// wire.
    private func richerWorldResponse() -> HTTPResponse {
        HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data([0x58, 0x15, 0x28, 0x07]))
    }

    // MARK: - The credential path

    @Test func aMissingCredentialSaysSoRatherThanFailingVaguely() async {
        let store = store(FakeSecretStorage())
        let text = await APIProbeReport.run(
            store: store,
            transport: ScriptedTransport([]),
            endpoints: ChatEndpoints()
        )
        #expect(text.contains("No session"))
    }

    /// A locked or broken Keychain is not an absent credential - same
    /// distinction `KeychainCredentialStoreTests` pins for the store itself,
    /// checked again here because the probe is a second place that could
    /// collapse the two.
    @Test func aKeychainFailureIsReportedRatherThanReadAsNoSession() async {
        let storage = FakeSecretStorage()
        storage.readError = Boom()
        let text = await APIProbeReport.run(
            store: store(storage),
            transport: ScriptedTransport([]),
            endpoints: ChatEndpoints()
        )
        #expect(text.contains("Keychain refused"))
        #expect(!text.contains("No session"))
    }

    // MARK: - What the bootstrap can conclude

    @Test func aBootstrapFailureStopsBeforeAnyAPICall() async throws {
        let storage = FakeSecretStorage()
        let credentialStore = store(storage)
        try await credentialStore.store(storedSession())
        let text = await APIProbeReport.run(
            store: credentialStore,
            transport: ScriptedTransport([.failure(Boom())]),
            endpoints: ChatEndpoints()
        )
        #expect(text.contains("bootstrap failed"))
        #expect(!text.contains("paginated_world"))
    }

    @Test func aSignedOutSessionStopsBeforeTheLadder() async throws {
        let storage = FakeSecretStorage()
        let credentialStore = store(storage)
        try await credentialStore.store(storedSession())
        let text = await APIProbeReport.run(
            store: credentialStore,
            transport: ScriptedTransport([.success(shell(app: "AccountsSignInUi"))]),
            endpoints: ChatEndpoints()
        )
        #expect(text.contains("NOT SIGNED IN"))
        #expect(!text.contains("paginated_world"))
        // The cookie count and byte count are safe to report even signed out;
        // the value behind them is not.
        #expect(text.contains("1 cookies"))
        #expect(!text.contains("SECRET-COOKIE-VALUE-DO-NOT-LEAK"))
    }

    // MARK: - Leak tests for each error path

    //
    // The fix-round finding: a happy-path leak test proves nothing about the
    // catch blocks, and those are exactly where an unguarded `\(error)` can
    // put a live transport error's own `description` into a report that gets
    // pasted into a committed file. Each test here plants a `SentinelError`
    // whose `description` is a distinctive sentinel at one specific failure
    // site and asserts the sentinel never reaches the returned string -
    // proving the claim rather than assuming today's concrete error types
    // stay the only ones that can ever reach that catch.

    /// `Bootstrap.run`'s `transport.send` is unguarded (`Bootstrap.swift:162`),
    /// so a raw transport failure reaches `appendBootstrap`'s catch as
    /// whatever type the transport happens to throw - not a type this
    /// package controls the `description` of.
    @Test func aBootstrapFailureNeverLeaksTheUnderlyingErrorDescription() async throws {
        let storage = FakeSecretStorage()
        let credentialStore = store(storage)
        try await credentialStore.store(storedSession())
        let sentinel = "SENTINEL-BOOTSTRAP-abc123"
        let text = await APIProbeReport.run(
            store: credentialStore,
            transport: ScriptedTransport([.failure(SentinelError(description: sentinel))]),
            endpoints: ChatEndpoints()
        )
        #expect(text.contains("bootstrap failed"))
        #expect(!text.contains(sentinel))
    }

    /// The `get_self_user_status` catch in `appendVerifiedCall`.
    @Test func aVerifiedCallFailureNeverLeaksTheUnderlyingErrorDescription() async throws {
        let storage = FakeSecretStorage()
        let credentialStore = store(storage)
        try await credentialStore.store(storedSession())
        let sentinel = "SENTINEL-VERIFIED-CALL-def456"
        let responses: [Result<HTTPResponse, any Error>] = [
            .success(shell(app: "DynamiteWebUi")),
            .failure(SentinelError(description: sentinel))
        ]
        let text = await APIProbeReport.run(
            store: credentialStore,
            transport: ScriptedTransport(responses),
            endpoints: ChatEndpoints()
        )
        #expect(text.contains("FAILED"))
        #expect(!text.contains("paginated_world"))
        #expect(!text.contains(sentinel))
    }

    /// A `paginated_world` rung failing. The sentinel is baked into
    /// `WorldRungResult.failure` inside `WorldRequestLadder.swift`, well
    /// before `APIProbeReport` sees it, so this also covers that this file
    /// does not own.
    @Test func aLadderRungFailureNeverLeaksTheUnderlyingErrorDescription() async throws {
        let storage = FakeSecretStorage()
        let credentialStore = store(storage)
        try await credentialStore.store(storedSession())
        let sentinel = "SENTINEL-LADDER-ghi789"
        let responses: [Result<HTTPResponse, any Error>] = try [
            .success(shell(app: "DynamiteWebUi")),
            .success(selfStatusResponse()),
            .failure(SentinelError(description: sentinel)),
            .failure(SentinelError(description: sentinel)),
            .failure(SentinelError(description: sentinel)),
            .failure(SentinelError(description: sentinel))
        ]
        let text = await APIProbeReport.run(
            store: credentialStore,
            transport: ScriptedTransport(responses),
            endpoints: ChatEndpoints()
        )
        #expect(text.contains("paginated_world ladder:"))
        #expect(text.contains("FAILED"))
        #expect(!text.contains(sentinel))
    }

    // MARK: - The full run, and the leak tests that justify the whole file

    @Test func aFullRunReportsTheLadderAndItsVerdict() async throws {
        let storage = FakeSecretStorage()
        let credentialStore = store(storage)
        try await credentialStore.store(storedSession())
        let responses: [Result<HTTPResponse, any Error>] = try [
            .success(shell(app: "DynamiteWebUi")),
            .success(selfStatusResponse()),
            .success(controlWorldResponse()),
            .success(richerWorldResponse()),
            .success(richerWorldResponse()),
            .success(richerWorldResponse())
        ]
        let text = await APIProbeReport.run(
            store: credentialStore,
            transport: ScriptedTransport(responses),
            endpoints: ChatEndpoints()
        )
        #expect(text.contains("get_self_user_status"))
        #expect(text.contains("OK - encoding raw, user id 6 chars"))
        #expect(text.contains("paginated_world ladder:"))
        #expect(text.contains("First rung to return more than the control:"))
    }

    /// The report is pasted verbatim into `findings.md` by a human. It must
    /// never carry the cookie value, the xsrf token or a user id - only their
    /// lengths. Named for the path it actually covers - the happy path -
    /// because the three tests above carry the rest of the claim, for the
    /// three catch blocks a success never reaches.
    @Test func aSuccessfulRunNeverCarriesACookieValueOrToken() async throws {
        let storage = FakeSecretStorage()
        let credentialStore = store(storage)
        try await credentialStore.store(storedSession())
        let responses: [Result<HTTPResponse, any Error>] = try [
            .success(shell(app: "DynamiteWebUi")),
            .success(selfStatusResponse(userID: "user-should-not-appear")),
            .success(controlWorldResponse()),
            .success(richerWorldResponse()),
            .success(richerWorldResponse()),
            .success(richerWorldResponse())
        ]
        let text = await APIProbeReport.run(
            store: credentialStore,
            transport: ScriptedTransport(responses),
            endpoints: ChatEndpoints()
        )
        #expect(!text.contains("SECRET-COOKIE-VALUE-DO-NOT-LEAK"))
        #expect(!text.contains("XSRF-TOKEN-SECRET-VALUE"))
        #expect(!text.contains("user-should-not-appear"))
    }

    /// The whole point of the `/api/` probe is a report a human reads and
    /// pastes into `findings.md`. It must never carry a cookie value, a token
    /// or a message.
    @Test func theHeaderNeverCarriesACookieValueOrToken() {
        let text = APIProbeReport.header(cookieCount: 26, byteCount: 4990, hasToken: true)
        #expect(text.contains("26"))
        #expect(text.contains("4990"))
        #expect(text.contains("present"))
    }
}
