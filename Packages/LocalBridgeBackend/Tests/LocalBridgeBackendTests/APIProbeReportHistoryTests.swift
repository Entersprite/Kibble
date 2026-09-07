import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `--probe=api`'s topics-ladder section (this slice's step 6) - the history
/// analogue of `APIProbeReportWorldMappingTests.swift`.
///
/// Helpers duplicated rather than shared, the same call that file's own doc
/// comment already makes about its own duplication from
/// `APIProbeReportTests.swift`: `private` is `private`, and a little
/// duplication is cheaper than a shared surface neither file actually needs
/// elsewhere.
@Suite("APIProbeReport - history")
struct APIProbeReportHistoryTests {
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
        KeychainCredentialStore(storage: storage, account: "probe-history-test")
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

    /// The control's field 11, plus a field the control never carries - still
    /// no real `world_items` entry.
    private func richerWorldResponse() -> HTTPResponse {
        HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data([0x58, 0x15, 0x28, 0x07]))
    }

    private func spaceGroupID(_ id: String) -> GroupId {
        var group = GroupId()
        var space = SpaceId()
        space.spaceID = id
        group.spaceID = space
        return group
    }

    /// One real `WorldItemLite` - a space, with no `dm_members`, so the
    /// member-resolution call this section runs *before* never fires and
    /// this file's response counts stay simple to reason about.
    private func worldResponse(spaceID: String) throws -> HTTPResponse {
        var item = WorldItemLite()
        item.groupID = spaceGroupID(spaceID)
        item.roomName = "irrelevant to this file"
        var response = PaginatedWorldResponse()
        response.worldItems = [item]
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    /// An empty `ListTopicsResponse` - a legal raw response for
    /// `TopicsRequestLadder`'s control rung, the same way the world ladder's
    /// own control does not require a decodable body either.
    private func emptyTopicsResponse() -> HTTPResponse {
        HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    /// A `ListTopicsResponse` carrying one topic and one reply - built as a
    /// typed `SwiftProtobuf` value, the same convention `WorldMappingTests`/
    /// `HistoryMappingTests` both use.
    private func topicsResponse(groupID: GroupId, messageID: String, text: String) throws -> HTTPResponse {
        var topicID = TopicId()
        topicID.groupID = groupID
        topicID.topicID = "t-1"
        var parent = MessageParentId()
        parent.topicID = topicID
        var wireMessageID = MessageId()
        wireMessageID.parentID = parent
        wireMessageID.messageID = messageID

        var message = GChatBridgeCore.Message()
        message.id = wireMessageID
        message.textBody = text
        message.createTime = 1_700_000_000_000_000

        var topic = Topic()
        topic.replies = [message]
        var response = ListTopicsResponse()
        response.topics = [topic]
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    /// Rung 4's own response: one topic with a real `createTimeUsec`, and a
    /// `read_receipt_set` carrying one receipt for `selfID` and one for a
    /// different user - enough for `ReadReceiptReport` to resolve both
    /// `self` and `other` and compute a real delta against the topic.
    private func topicsResponseWithReceipts(
        groupID: GroupId,
        selfID: String,
        selfReadTimeMicros: Int64,
        otherReadTimeMicros: Int64,
        topicCreateTimeUsec: Int64
    ) throws -> HTTPResponse {
        var topicID = TopicId()
        topicID.groupID = groupID
        topicID.topicID = "t-1"

        var topic = Topic()
        topic.id = topicID
        topic.createTimeUsec = topicCreateTimeUsec

        func receipt(userID: String, readTimeMicros: Int64) -> ReadReceipt {
            var user = User()
            var id = UserId()
            id.id = userID
            user.userID = id
            var receipt = ReadReceipt()
            receipt.user = user
            receipt.readTimeMicros = readTimeMicros
            return receipt
        }

        var receiptSet = ReadReceiptSet()
        receiptSet.enabled = true
        receiptSet.readReceipts = [
            receipt(userID: selfID, readTimeMicros: selfReadTimeMicros),
            receipt(userID: "SENTINEL-OTHER-USER-ID-should-not-appear", readTimeMicros: otherReadTimeMicros)
        ]

        var response = ListTopicsResponse()
        response.topics = [topic]
        response.readReceiptSet = receiptSet
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    // MARK: - No conversation to probe

    @Test func aRunWithNoConversationsSkipsTheTopicsLadderCleanly() async throws {
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
            .success(controlWorldResponse()) // the mapping summary's own call - no real items
        ]
        let text = await APIProbeReport.run(
            store: credentialStore,
            transport: ScriptedTransport(responses),
            endpoints: ChatEndpoints()
        )
        #expect(text.contains("list_topics ladder:"))
        #expect(text.contains("no conversation available to probe"))
        #expect(!text.contains("probing conversation index"))
    }

    // MARK: - A real conversation

    /// The full path: one real conversation from the world mapping, its
    /// `GroupId` recovered by `ChannelEventMapping.groupID(for:)`, the four
    /// `list_topics` rungs sent against it, and `HistoryMapping`'s own count
    /// summary over the minimum-viable rung. **Counts and field numbers
    /// only** - never the space id, the message id or the text that produced
    /// them.
    @Test func aRunWithARealConversationRunsTheTopicsLadderAgainstIt() async throws {
        let storage = FakeSecretStorage()
        let credentialStore = store(storage)
        try await credentialStore.store(storedSession())
        let spaceID = "SENTINEL-SPACE-ID-should-not-appear"
        let messageID = "SENTINEL-MESSAGE-ID-should-not-appear"
        let text = "SENTINEL-MESSAGE-TEXT-should-not-appear"
        let selfID = "SENTINEL-SELF-USER-ID-should-not-appear"
        let group = spaceGroupID(spaceID)
        let worldItemResponse = try worldResponse(spaceID: spaceID)
        let topicsRungResponse = try topicsResponse(groupID: group, messageID: messageID, text: text)
        // The newest topic's `createTimeUsec` a full 2.5 seconds ahead of
        // "self"'s own read receipt and 10 seconds ahead of "other"'s -
        // deliberately not zero, so a passing test proves the delta is
        // actually computed rather than two zeros matching by accident.
        let newestCreateTimeUsec: Int64 = 1_700_000_010_000_000
        let receiptsResponse = try topicsResponseWithReceipts(
            groupID: group,
            selfID: selfID,
            selfReadTimeMicros: newestCreateTimeUsec - 2_500_000,
            otherReadTimeMicros: newestCreateTimeUsec - 10_000_000,
            topicCreateTimeUsec: newestCreateTimeUsec
        )

        let responses: [Result<HTTPResponse, any Error>] = try [
            .success(shell(app: "DynamiteWebUi")),
            .success(selfStatusResponse(userID: selfID)),
            .success(controlWorldResponse()), // world ladder rung 1
            .success(worldItemResponse), // world ladder rung 2
            .success(worldItemResponse), // world ladder rung 3
            .success(worldItemResponse), // world ladder rung 4
            .success(worldItemResponse), // the mapping summary's own paginated_world call
            .success(emptyTopicsResponse()), // topics ladder rung 1 (control)
            .success(topicsRungResponse), // topics ladder rung 2
            .success(topicsRungResponse), // topics ladder rung 3
            .success(topicsRungResponse), // topics ladder rung 4
            .success(topicsRungResponse), // the history mapping summary's own list_topics call
            .success(receiptsResponse) // the read-receipts section's own rung-4 list_topics call
        ]
        let reportText = await APIProbeReport.run(
            store: credentialStore,
            transport: ScriptedTransport(responses),
            endpoints: ChatEndpoints()
        )
        #expect(reportText.contains("list_topics ladder:"))
        #expect(reportText.contains("probing conversation index 0 of 1"))
        #expect(reportText.contains("topic nested shape"))
        #expect(reportText.contains("topic 1:"))
        #expect(reportText.contains("history mapping summary (list_topics, minimum viable rung):"))
        #expect(reportText.contains("messages: 1, skipped: 0"))
        #expect(reportText.contains("with non-empty text: 1"))
        assertReadReceiptsSection(
            reportText,
            leakCandidates: [spaceID, messageID, text, selfID, "SENTINEL-OTHER-USER-ID-should-not-appear"]
        )
    }

    /// The read-receipts section's own assertions, split out of
    /// `aRunWithARealConversationRunsTheTopicsLadderAgainstIt` purely to keep
    /// that test under `swiftlint`'s `function_body_length` ceiling - not a
    /// second scenario, so it stays beside its one caller rather than
    /// becoming a `@Test` of its own.
    private func assertReadReceiptsSection(_ reportText: String, leakCandidates: [String]) {
        // Enabled, both receipts resolved by id against the self status
        // response, and a real (non-zero) delta for each - not printed as an
        // id, a name or an absolute timestamp.
        #expect(reportText.contains("read receipts (list_topics rung 4"))
        #expect(reportText.contains("read receipts enabled: true"))
        #expect(reportText.contains("receipts: 2"))
        #expect(reportText.contains("receipt self: -2500000µs vs reference"))
        #expect(reportText.contains("receipt other: -10000000µs vs reference"))
        #expect(!reportText.contains("self could not be identified"))
        for candidate in leakCandidates {
            #expect(!reportText.contains(candidate))
        }
    }

    // MARK: - Leak tests for the two new catch blocks

    /// A `list_topics` rung failing. The sentinel is baked into
    /// `TopicsRungResult.failure` inside `TopicsRequestLadder.swift`, well
    /// before this file sees it - the topics analogue of
    /// `APIProbeReportTests.aLadderRungFailureNeverLeaksTheUnderlyingErrorDescription`.
    @Test func aTopicsLadderRungFailureNeverLeaksTheUnderlyingErrorDescription() async throws {
        let storage = FakeSecretStorage()
        let credentialStore = store(storage)
        try await credentialStore.store(storedSession())
        let spaceID = "s-1"
        let worldItemResponse = try worldResponse(spaceID: spaceID)
        let sentinel = "SENTINEL-TOPICS-LADDER-pqr678"
        let responses: [Result<HTTPResponse, any Error>] = try [
            .success(shell(app: "DynamiteWebUi")),
            .success(selfStatusResponse()),
            .success(controlWorldResponse()),
            .success(worldItemResponse),
            .success(worldItemResponse),
            .success(worldItemResponse),
            .success(worldItemResponse), // the mapping summary's own call
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
        #expect(text.contains("list_topics ladder:"))
        #expect(text.contains("FAILED"))
        #expect(!text.contains(sentinel))
    }

    /// The history mapping summary's own `list_topics` call, separate from
    /// the ladder - the topics analogue of
    /// `APIProbeReportWorldMappingTests.aMappingSummaryFailureNeverLeaksTheUnderlyingErrorDescription`.
    @Test func aHistoryMappingSummaryFailureNeverLeaksTheUnderlyingErrorDescription() async throws {
        let storage = FakeSecretStorage()
        let credentialStore = store(storage)
        try await credentialStore.store(storedSession())
        let spaceID = "s-1"
        let worldItemResponse = try worldResponse(spaceID: spaceID)
        let sentinel = "SENTINEL-HISTORY-MAPPING-stu901"
        let responses: [Result<HTTPResponse, any Error>] = try [
            .success(shell(app: "DynamiteWebUi")),
            .success(selfStatusResponse()),
            .success(controlWorldResponse()),
            .success(worldItemResponse),
            .success(worldItemResponse),
            .success(worldItemResponse),
            .success(worldItemResponse), // the mapping summary's own call
            .success(emptyTopicsResponse()), // topics ladder rung 1
            .success(emptyTopicsResponse()), // topics ladder rung 2
            .success(emptyTopicsResponse()), // topics ladder rung 3
            .success(emptyTopicsResponse()), // topics ladder rung 4
            .failure(SentinelError(description: sentinel)), // the history mapping summary's own call
            .failure(SentinelError(description: sentinel)) // the read-receipts section's own call
        ]
        let text = await APIProbeReport.run(
            store: credentialStore,
            transport: ScriptedTransport(responses),
            endpoints: ChatEndpoints()
        )
        #expect(text.contains("history mapping summary (list_topics, minimum viable rung):"))
        #expect(text.contains("FAILED"))
        #expect(!text.contains(sentinel))
    }

    /// The read-receipts section's own rung-4 `list_topics` call failing -
    /// the read-receipts analogue of the two leak tests above.
    @Test func aReadReceiptsSectionFailureNeverLeaksTheUnderlyingErrorDescription() async throws {
        let storage = FakeSecretStorage()
        let credentialStore = store(storage)
        try await credentialStore.store(storedSession())
        let spaceID = "s-1"
        let worldItemResponse = try worldResponse(spaceID: spaceID)
        let sentinel = "SENTINEL-READ-RECEIPTS-vwx234"
        let responses: [Result<HTTPResponse, any Error>] = try [
            .success(shell(app: "DynamiteWebUi")),
            .success(selfStatusResponse()),
            .success(controlWorldResponse()),
            .success(worldItemResponse),
            .success(worldItemResponse),
            .success(worldItemResponse),
            .success(worldItemResponse), // the mapping summary's own call
            .success(emptyTopicsResponse()), // topics ladder rung 1
            .success(emptyTopicsResponse()), // topics ladder rung 2
            .success(emptyTopicsResponse()), // topics ladder rung 3
            .success(emptyTopicsResponse()), // topics ladder rung 4
            .success(emptyTopicsResponse()), // the history mapping summary's own call
            .failure(SentinelError(description: sentinel)) // the read-receipts section's own call
        ]
        let text = await APIProbeReport.run(
            store: credentialStore,
            transport: ScriptedTransport(responses),
            endpoints: ChatEndpoints()
        )
        #expect(text.contains("read receipts (list_topics rung 4"))
        #expect(text.contains("FAILED"))
        #expect(!text.contains(sentinel))
    }
}
