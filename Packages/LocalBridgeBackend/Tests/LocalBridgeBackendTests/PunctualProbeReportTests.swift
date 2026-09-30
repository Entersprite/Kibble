import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `--probe=punctual`'s opening: the api probe's credential and bootstrap,
/// then the Punctual key, which the capture found as `Tzliq` on `/app/home`
/// (`findings.md` §47). The channel itself is `PunctualWatchRunTests`'.
struct PunctualProbeReportTests {
    /// A second minimal copy, for the reason `APIProbeReportTests` gives for
    /// its own: the Keychain test's fake is `private` to its file.
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

    private func storedStore() async throws -> KeychainCredentialStore {
        let store = KeychainCredentialStore(storage: FakeSecretStorage(), account: "punctual-test")
        try await store.store(StoredSession(
            credential: SessionCookies(cookies: [SessionCookies.Cookie(
                name: "SID",
                value: "COOKIE-SECRET"
            )])!,
            capturedAt: .now,
            expiresAt: nil
        ))
        return store
    }

    private func page(tzliq: String?) -> Result<HTTPResponse, any Error> {
        let key = tzliq.map { #","Tzliq":"\#($0)""# } ?? ""
        let html = #"<script>window.WIZ_global_data = {"qwAQke":"DynamiteWebUi","SMqcke":"XSRF""#
            + key + "};</script>"
        return .success(HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(html.utf8)))
    }

    private func selfStatus() throws -> Result<HTTPResponse, any Error> {
        var response = GetSelfUserStatusResponse()
        var status = UserStatus()
        var identifier = UserId()
        identifier.id = "self-id"
        status.userID = identifier
        response.userStatus = status
        return try .success(HTTPResponse(
            status: 200,
            headers: HTTPHeaders([]),
            body: response.serializedBytes()
        ))
    }

    private func run(_ responses: [Result<HTTPResponse, any Error>]) async throws -> (String, [HTTPRequest]) {
        let transport = ScriptedTransport(responses)
        let text = try await PunctualProbeReport.run(
            store: storedStore(), transport: transport, endpoints: ChatEndpoints(), flush: { _ in }
        )
        return await (text, transport.sent)
    }

    @Test func withNoKeyOnEitherPageTheProbeStopsBeforePunctual() async throws {
        let (text, sent) = try await run([page(tzliq: nil), selfStatus(), page(tzliq: nil)])
        #expect(text.contains("Stopping: no Punctual key (Tzliq) in /app/home or the mole shell."))
        #expect(sent.last?.traceLabel == "app-home")
    }

    /// The chat host's key is the one on `/app/home`. The mole shell's is a
    /// fallback whose equality with it is `[Verify]`.
    @Test func theAppHomeKeyWinsOverTheMoleShells() async throws {
        let (text, _) = try await run([page(tzliq: "MOLE-KEY"), selfStatus(), page(tzliq: "HOME-KEY")])
        #expect(text.contains("key source: app/home"))
        #expect(!text.contains("HOME-KEY"))
        #expect(!text.contains("MOLE-KEY"))
    }

    @Test func theMoleShellsKeyIsTheFallback() async throws {
        let (text, _) = try await run([page(tzliq: "MOLE-KEY"), selfStatus(), page(tzliq: nil)])
        #expect(text.contains("key source: mole shell"))
    }

    @Test func theReportCarriesItsConfigRowAndNoCredential() async throws {
        let (text, _) = try await run([page(tzliq: nil), selfStatus(), page(tzliq: nil)])
        #expect(text.contains("config: build "))
        #expect(text.contains("server path prod-09-us"))
        #expect(!text.contains("COOKIE-SECRET"))
        #expect(!text.contains("XSRF\""))
    }
}
