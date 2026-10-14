import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@Suite(.timeLimit(.minutes(1)))
struct CachedHistoryCursorTests {
    private let space = Conversation.ID("space/s-1")
    private let rootID = ChatKit.Message.ID("cached-root")
    private let micros: Int64 = 1_790_123_456_789_012

    private func message(
        _ id: String = "cached-root", topic: String = "cached-root", space: String = "s-1",
        at time: Int64? = nil, deleted: Bool = false, reply: Bool = false
    ) -> GChatBridgeCore.Message {
        var message = GChatBridgeCore.Message()
        message.id.messageID = id
        message.id.parentID.topicID.topicID = topic
        message.id.parentID.topicID.groupID.spaceID.spaceID = space
        message.creator.userID.id = "u-1"
        message.createTime = time ?? micros
        message.textBody = "cached"
        if deleted {
            message.deleteTime = micros + 1
        }
        if reply {
            message.isInlineReply = true
        }
        return message
    }

    private func roots(_ messages: [GChatBridgeCore.Message]) throws -> Data {
        var response = ListMessagesResponse()
        response.messages = messages
        // Empty protobuf replies still need a nonempty body for API decoding.
        response.groupRevision = ReadRevision()
        return try response.serializedBytes()
    }

    private func history() throws -> Data {
        var response = ListTopicsResponse()
        response.containsFirstTopic = true
        var topic = Topic()
        topic.id.topicID = "older"
        topic.id.groupID.spaceID.spaceID = "s-1"
        topic.replies = [message("older", topic: "older", at: micros - 1)]
        var rootTopic = Topic()
        rootTopic.id = message().id.parentID.topicID
        rootTopic.replies = [message()]
        response.topics = [topic, rootTopic]
        return try response.serializedBytes()
    }

    private func connected(
        root: [GChatBridgeCore.Message], held: Set<String> = []
    ) async throws -> (LocalBridgeBackend, ThreadCallTransport) {
        let transport = try ThreadCallTransport(answers: [
            "list_messages": roots(root), "list_topics": history(),
            "get_self_user_status": SearchTransport.selfStatusResponse("u-me").body
        ], holding: held)
        let cookies = try #require(SessionCookies(header: "SID=a; COMPASS=b; OSID=c"))
        let backend = LocalBridgeBackend(cookies: cookies, transport: transport)
        try await backend.connect()
        return (backend, transport)
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0 ..< 400 {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    @Test func aPersistedUnmappedRootResolvesOnceThenRequestsStrictlyOlderHistory() async throws {
        let (backend, transport) = try await connected(root: [message()])
        #expect(await backend.messageTimes.micros(of: rootID) == nil)
        let page = try await backend.loadMessages(in: space, before: rootID)
        #expect(page.map(\.id.rawValue) == ["older"])
        let lookup = try #require(await transport.bodies(of: "list_messages").first)
        let request = try ListMessagesRequest(serializedBytes: lookup)
        #expect(request.pageSize == 1)
        #expect(request.parentID.topicID.topicID == rootID.rawValue)
        #expect(request.parentID.topicID.groupID.spaceID.spaceID == "s-1")
        let topicBody = try #require(await transport.bodies(of: "list_topics").first)
        let topics = try ListTopicsRequest(serializedBytes: topicBody)
        #expect(topics.filter.anchor.timeUsec == micros)
        #expect(topics.sortOption == 2)
        _ = try await backend.loadMessages(in: space, before: rootID)
        #expect(await transport.bodies(of: "list_messages").count == 1)
        await backend.disconnect()
    }

    @Test func aDeletedRootWithAnOriginalCreateTimeStillAnchorsHistory() async throws {
        let (backend, transport) = try await connected(root: [message(deleted: true)])
        let page = try await backend.loadMessages(in: space, before: rootID)
        #expect(page.map(\.id.rawValue) == ["older"])
        #expect(await backend.messageTimes.micros(of: rootID) == micros)
        #expect(await transport.bodies(of: "list_topics").count == 1)
        await backend.disconnect()
    }

    @Test func missingForeignReplyOrInvalidTimeCursorRefusesWithoutNewestFallback() async throws {
        var missingTime = message()
        missingTime.clearCreateTime()
        let invalid = [
            [], [missingTime], [message("different")], [message(topic: "different")],
            [message(space: "different")], [message(reply: true)], [message(at: 0)],
            [message(), message("extra")]
        ]
        for root in invalid {
            let (backend, transport) = try await connected(root: root)
            await #expect(throws: ChatError.self) {
                _ = try await backend.loadMessages(in: space, before: rootID)
            }
            #expect(await transport.bodies(of: "list_topics").isEmpty)
            #expect(await backend.messageTimes.isEmpty)
            await backend.disconnect()
        }
    }

    @Test func aCanceledRootLookupCannotRememberOrRequestAnOlderPage() async throws {
        let (backend, transport) = try await connected(root: [], held: ["list_messages"])
        let load = Task { try await backend.loadMessages(in: space, before: rootID) }
        #expect(await eventually { await transport.bodies(of: "list_messages").count == 1 })
        load.cancel()
        try await transport.answer("list_messages", with: roots([message()]))
        await #expect(throws: CancellationError.self) { _ = try await load.value }
        #expect(await backend.messageTimes.isEmpty)
        #expect(await transport.bodies(of: "list_topics").isEmpty)
        await backend.disconnect()
    }

    @Test func aRootLookupAnswerCannotReachAReplacementSession() async throws {
        let (backend, transport) = try await connected(root: [], held: ["list_messages"])
        let load = Task { try await backend.loadMessages(in: space, before: rootID) }
        #expect(await eventually { await transport.bodies(of: "list_messages").count == 1 })
        await backend.disconnect()
        try await backend.connect()
        try await transport.answer("list_messages", with: roots([message()]))
        await #expect(throws: CancellationError.self) { _ = try await load.value }
        #expect(await backend.messageTimes.isEmpty)
        #expect(await transport.bodies(of: "list_topics").isEmpty)
        await backend.disconnect()
    }
}
