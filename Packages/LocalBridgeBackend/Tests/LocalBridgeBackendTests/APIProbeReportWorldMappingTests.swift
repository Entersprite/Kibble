import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The two sections `--probe=api` adds after the ladder: the nested
/// `world_item` field shape (§20.4's `[Verify]`) and the `WorldMapping`
/// summary over rung 2.
///
/// Split out of `APIProbeReportTests.swift` rather than grown inside it -
/// `swiftlint`'s `file_length`/`type_body_length` are real signals once a
/// suite covers two genuinely separate report sections, and each file stays
/// readable as one concern. The helpers below duplicate a few of that file's
/// (`FakeSecretStorage`, `store(_:)`, `storedSession()`, `shell(app:)`,
/// `selfStatusResponse`, `controlWorldResponse`, `richerWorldResponse`)
/// rather than widening their access - `private` is `private` because
/// `ScriptedTransport.swift`'s own doc comment already made that call for
/// this test target: a little duplication is cheaper than a shared surface
/// neither file actually needs elsewhere.
@Suite("APIProbeReport - world mapping")
struct APIProbeReportWorldMappingTests {
    private struct SentinelError: Error, CustomStringConvertible {
        let description: String
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

    private func store(_ storage: FakeSecretStorage) -> KeychainCredentialStore {
        KeychainCredentialStore(storage: storage, account: "probe-world-mapping-test")
    }

    private func storedSession() -> StoredSession {
        StoredSession(
            credential: SessionCookies(cookies: [
                SessionCookies.Cookie(name: "SID", value: "SECRET-COOKIE-VALUE-DO-NOT-LEAK")
            ])!,
            capturedAt: .now,
            expiresAt: nil
        )
    }

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
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    /// Field 11 only - §3.6's control shape.
    private func controlWorldResponse() -> HTTPResponse {
        HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data([0x58, 0x15]))
    }

    /// The control's field 11, plus a field the control never carries - a
    /// rung that answers with more than the control, but still with no real
    /// `world_items` (field 4) entry.
    private func richerWorldResponse() -> HTTPResponse {
        HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data([0x58, 0x15, 0x28, 0x07]))
    }

    /// A real `PaginatedWorldResponse` carrying one `WorldItemLite`, built as
    /// a typed `SwiftProtobuf` value rather than hand-encoded bytes - this is
    /// what a rung 2/3/4 response actually contains once `world_items` is
    /// populated, and it is what both new sections have real content to
    /// report against.
    private func worldResponse(roomName: String, memberID: String) throws -> HTTPResponse {
        var group = GroupId()
        var space = SpaceId()
        space.spaceID = "s-1"
        group.spaceID = space

        var item = WorldItemLite()
        item.groupID = group
        item.roomName = roomName
        var members = WorldItemLite.DmMembers()
        var user = UserId()
        user.id = memberID
        members.members = [user]
        item.dmMembers = members

        var response = PaginatedWorldResponse()
        response.worldItems = [item]
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    // MARK: - Leak test for the mapping summary's own catch block

    /// A second `/api/` call, separate from the ladder, and its own place an
    /// unguarded `\(error)` could leak.
    @Test func aMappingSummaryFailureNeverLeaksTheUnderlyingErrorDescription() async throws {
        let storage = FakeSecretStorage()
        let credentialStore = store(storage)
        try await credentialStore.store(storedSession())
        let sentinel = "SENTINEL-MAPPING-jkl012"
        let responses: [Result<HTTPResponse, any Error>] = try [
            .success(shell(app: "DynamiteWebUi")),
            .success(selfStatusResponse()),
            .success(controlWorldResponse()),
            .success(richerWorldResponse()),
            .success(richerWorldResponse()),
            .success(richerWorldResponse()),
            .failure(SentinelError(description: sentinel))
        ]
        let text = await APIProbeReport.run(
            store: credentialStore,
            transport: ScriptedTransport(responses),
            endpoints: ChatEndpoints()
        )
        #expect(text.contains("world mapping summary"))
        #expect(text.contains("FAILED"))
        #expect(!text.contains(sentinel))
    }

    // MARK: - Both sections, against real content

    /// No rung carried a real `world_items` entry in this fixture
    /// (`richerWorldResponse()` has no field 4 at all), so both new sections
    /// must say so cleanly rather than reporting a truncated or crashed scan.
    @Test func aRunWithNoRealWorldItemsReportsBothSectionsAsEmpty() async throws {
        let storage = FakeSecretStorage()
        let credentialStore = store(storage)
        try await credentialStore.store(storedSession())
        let responses: [Result<HTTPResponse, any Error>] = try [
            .success(shell(app: "DynamiteWebUi")),
            .success(selfStatusResponse()),
            .success(controlWorldResponse()),
            .success(richerWorldResponse()),
            .success(richerWorldResponse()),
            .success(richerWorldResponse()),
            .success(controlWorldResponse()) // the mapping summary's own call
        ]
        let text = await APIProbeReport.run(
            store: credentialStore,
            transport: ScriptedTransport(responses),
            endpoints: ChatEndpoints()
        )
        #expect(text.contains("no world_items in any rung"))
        #expect(text.contains("world mapping summary (rung 2):"))
        #expect(text.contains("conversations: 0, skipped: 0"))
    }

    /// The nested-shape section reports real field numbers once a rung
    /// actually carries a `world_items` entry, and the mapping summary
    /// reports real counts from the same shape - both **counts and field
    /// numbers only**, never the room name or member id that produced them.
    @Test func aFullRunReportsTheNestedShapeAndMappingSummaryCountsButNeverAValue() async throws {
        let storage = FakeSecretStorage()
        let credentialStore = store(storage)
        try await credentialStore.store(storedSession())
        let roomName = "SENTINEL-ROOM-NAME-should-not-appear"
        let memberID = "SENTINEL-MEMBER-ID-should-not-appear"
        let itemResponse = try worldResponse(roomName: roomName, memberID: memberID)
        let responses: [Result<HTTPResponse, any Error>] = try [
            .success(shell(app: "DynamiteWebUi")),
            .success(selfStatusResponse()),
            .success(controlWorldResponse()),
            .success(itemResponse),
            .success(itemResponse),
            .success(itemResponse),
            .success(itemResponse) // the mapping summary's own call
        ]
        let text = await APIProbeReport.run(
            store: credentialStore,
            transport: ScriptedTransport(responses),
            endpoints: ChatEndpoints()
        )
        #expect(text.contains("world_item nested shape"))
        #expect(text.contains("item 1:"))
        #expect(text.contains("world mapping summary (rung 2):"))
        #expect(text.contains("conversations: 1, skipped: 0"))
        #expect(text.contains("spaces: 1, DMs: 0"))
        #expect(text.contains("with title: 1"))
        #expect(text.contains("total members across all conversations: 1"))
        #expect(!text.contains(roomName))
        #expect(!text.contains(memberID))
    }
}
