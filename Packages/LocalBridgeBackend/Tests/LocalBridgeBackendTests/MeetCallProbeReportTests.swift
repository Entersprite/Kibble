import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct MeetCallProbeReportTests {
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

    @Test func aHumanDMUsesTheBridgeConversationIDMapping() {
        let dm = Conversation(id: .init("dm/d-1"), kind: .directMessage)
        #expect(MeetCallProbeReport.dmID(for: dm) == "d-1")
    }

    @Test func otherConversationKindsAndMalformedIDsCannotResolve() {
        let appDM = Conversation(id: .init("dm/d-1"), kind: .appDirectMessage)
        let group = Conversation(id: .init("space/s-1"), kind: .groupDirectMessage)
        let malformed = Conversation(id: .init("dm:d-1"), kind: .directMessage)
        #expect(MeetCallProbeReport.dmID(for: appDM) == nil)
        #expect(MeetCallProbeReport.dmID(for: group) == nil)
        #expect(MeetCallProbeReport.dmID(for: malformed) == nil)
    }

    @Test func resolveProbeSignsTheMeetRequestAndReportsOnlySafeRefusalFacts() async throws {
        let store = KeychainCredentialStore(storage: FakeStorage(), account: "meet-proof-test")
        let cookies = try #require(SessionCookies(cookies: [
            .init(name: "SAPISID", value: "cookie-sentinel", domain: ".google.com", path: "/"),
            .init(name: "MOSID", value: "meet-sentinel", domain: "meet.google.com", path: "/"),
            .init(name: "OSID", value: "chat-sentinel", domain: "chat.google.com", path: "/")
        ]))
        try await store.store(StoredSession(credential: cookies, capturedAt: .now, expiresAt: nil))
        var world = PaginatedWorldResponse()
        world.worldItems = [WorldItemFixture.item(
            groupID: WorldItemFixture.dmGroupID("private-dm"),
            dmMembers: ["private-person", "self"], groupType: .oneToOneHumanDm
        )]
        let key = "AIza" + String(repeating: "K", count: 35)
        let body = Data(#"{"error":{"code":403,"status":"PERMISSION_DENIED","message":"private-error"}}"#
            .utf8)
        let transport = try ScriptedTransport([
            ScriptedTransport.ok(LocalBridgeBackendTests.shell(app: "DynamiteWebUi")),
            .success(HTTPResponse(status: 200, headers: HTTPHeaders([]), body: world.serializedBytes())),
            ScriptedTransport.ok("<script>window.WIZ_global_data={};</script>\(key) \(key)"),
            .success(HTTPResponse(status: 403, headers: HTTPHeaders([]), body: body))
        ])

        let report = await MeetCallProbeReport.run(store: store, transport: transport)
        let sent = await transport.sent
        #expect(sent.count == 4)
        let resolve = try #require(sent.last)
        #expect(resolve.url.path.hasSuffix("ResolveForHangoutsChat"))
        #expect(resolve.headers["Authorization"]?.hasPrefix("SAPISIDHASH ") == true)
        #expect(resolve.headers["Cookie"]?.contains("MOSID=meet-sentinel") == true)
        #expect(resolve.headers["Cookie"]?.contains("OSID=chat-sentinel") == false)
        #expect(report
            .contains("ResolveForHangoutsChat: HTTP 403; error body json; code 403; PERMISSION_DENIED"))
        for secret in [
            "cookie-sentinel",
            "meet-sentinel",
            "chat-sentinel",
            "private-dm",
            "private-error",
            key
        ] {
            #expect(!report.contains(secret))
        }
    }
}
