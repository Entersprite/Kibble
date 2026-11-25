import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

private actor EditTransport: HTTPTransport {
    struct NoStream: Error {}
    private let shell: HTTPResponse
    private let failure: (any Error)?
    private let original: GChatBridgeCore.Message
    private(set) var sent: [HTTPRequest] = []

    init(shell: HTTPResponse, original: GChatBridgeCore.Message, failure: (any Error)? = nil) {
        self.shell = shell
        self.failure = failure
        self.original = original
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        if request.url.path.contains("/mole/world") {
            return shell
        }
        if request.url.path.hasSuffix("/get_message") {
            var response = GetMessageResponse()
            response.message = original
            return try HTTPResponse(status: 200, headers: .init([]), body: response.serializedBytes())
        }
        if request.url.path.contains("/api/edit_message") || request.url.path
            .contains("/api/delete_message") {
            if let failure {
                throw failure
            }
            // One field, so the body is not empty: `ProtoAPIClient` answers
            // `.emptyBody` for zero bytes.
            var response = DeleteMessageResponse()
            response.groupSortTime = 1
            return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }

    func bodies(_ path: String) -> [Data] {
        sent.filter { $0.url.path.contains(path) }.compactMap(\.body)
    }
}

/// `.editMessage` and `.deleteMessage` through `edit_message` and
/// `delete_message`, reached through a real `connect()` (edit spec §3).
@Suite(.timeLimit(.minutes(1)))
struct EditDeleteMessageTests {
    private static let cookies = SessionCookies(header: "SID=a; COMPASS=b; OSID=c")!

    private static func subject() -> GChatBridgeCore.Message {
        var message = GChatBridgeCore.Message()
        message.id.parentID.topicID.groupID.spaceID.spaceID = "s-1"
        message.id.parentID.topicID.topicID = "t-1"
        message.id.messageID = "m-1"
        message.messageType = .userMessage
        return message
    }

    private func connected(
        failure: (any Error)? = nil, original: GChatBridgeCore.Message? = nil
    ) async throws -> (LocalBridgeBackend, EditTransport) {
        let html = LocalBridgeBackendTests.shell(app: "DynamiteWebUi")
        let transport = EditTransport(
            shell: HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(html.utf8)),
            original: original ?? Self.subject(),
            failure: failure
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()
        return (backend, transport)
    }

    private func edit(
        conversation: String? = "space/s-1", thread: String? = "t-1", id: String = "m-1",
        text: String = "fixed", mentions: [ChatKit.Mention] = []
    ) -> ChatCommand {
        .editMessage(
            id: ChatKit.Message.ID(id), text: text,
            conversationID: conversation.map { Conversation.ID($0) },
            threadID: thread.map { MessageThread.ID($0) }, mentions: mentions
        )
    }

    private func delete(conversation: String? = "space/s-1", thread: String? = "t-1", id: String = "m-1")
        -> ChatCommand {
        .deleteMessage(
            id: ChatKit.Message.ID(id), conversationID: conversation.map { Conversation.ID($0) },
            threadID: thread.map { MessageThread.ID($0) }
        )
    }

    @Test func theBackendAdvertisesEditAndDelete() async throws {
        let (backend, _) = try await connected()
        #expect(backend.capabilities.canEditMessages)
        #expect(backend.capabilities.canDeleteMessages)
    }

    @Test func anEditPostsTheBuildersShape() async throws {
        let (backend, transport) = try await connected()
        try await backend.send(edit())
        let body = try #require(await transport.bodies("/api/edit_message").first)
        let decoded = try EditMessageRequest(serializedBytes: body)
        let expected = try MessageEditRequests.editMessage(
            group: #require(ChannelEventMapping.groupID(for: Conversation.ID("space/s-1"))),
            topicID: "t-1", messageID: "m-1", text: "fixed", annotations: []
        )
        #expect(decoded.messageID == expected.messageID)
        #expect(decoded.textBody == "fixed")
        #expect(decoded.messageInfo.acceptFormatAnnotations)
        #expect(!decoded.messageInfo.hasReplyTo)
    }

    @Test func captionEditRetainsTheExactProviderQuoteAcrossConversations() async throws {
        var original = Self.subject()
        original.replyTo.id.parentID.topicID.groupID.dmID.dmID = "source"
        original.replyTo.id.parentID.topicID.topicID = "source-topic"
        original.replyTo.id.messageID = "quoted"
        original.replyTo.createTime = 2_000_000
        original.replyTo.referenceType = 1
        let (backend, transport) = try await connected(original: original)
        try await backend.send(edit())
        let reads = await transport.bodies("/api/get_message")
        let read = try GetMessageRequest(serializedBytes: #require(reads.first))
        #expect(reads.count == 1)
        #expect(read.messageID == original.id)
        let body = try #require(await transport.bodies("/api/edit_message").first)
        let request = try EditMessageRequest(serializedBytes: body)
        let reply = request.messageInfo.replyTo
        #expect(reply.id == original.replyTo.id)
        #expect(reply.createTime == original.replyTo.createTime)
        #expect(reply.referenceType == 1)
    }

    @Test func anIncompleteReferenceRefusesAnEditWithoutRemovingTheReference() async throws {
        var original = Self.subject()
        var marker = Annotation()
        marker.type = .replyReference
        original.annotations = [marker]
        let (backend, transport) = try await connected(original: original)
        await #expect(throws: ChatError.self) { try await backend.send(edit()) }
        #expect(await transport.bodies("/api/edit_message").isEmpty)
    }

    /// An edit never invites: whatever mode a mention arrives with, the wire
    /// carries no `INVITE` and no "mention without adding" (edit spec §3).
    @Test func anEditNeverInvites() async throws {
        let (backend, transport) = try await connected()
        let everyone = ChatKit.Mention(target: .all, start: 0, length: 4)
        let invite = ChatKit.Mention(
            target: .user(ChatKit.Member.ID("u-1")),
            start: 5,
            length: 3,
            mode: .invite
        )
        let outside = ChatKit.Mention(
            target: .user(ChatKit.Member.ID("u-2")), start: 9, length: 3, mode: .withoutAdding
        )
        try await backend.send(edit(text: "@all @Al @Bo", mentions: [everyone, invite, outside]))
        let body = try #require(await transport.bodies("/api/edit_message").first)
        let decoded = try EditMessageRequest(serializedBytes: body)
        let types = decoded.annotations.map(\.userMentionMetadata.type)
        #expect(types == [.mentionAll, .mention, .mention])
    }

    @Test func aDeletePostsTheMessageID() async throws {
        let (backend, transport) = try await connected()
        try await backend.send(delete())
        let body = try #require(await transport.bodies("/api/delete_message").first)
        let decoded = try DeleteMessageRequest(serializedBytes: body)
        #expect(decoded.messageID.messageID == "m-1")
        #expect(decoded.messageID.parentID.topicID.topicID == "t-1")
        #expect(decoded.messageID.parentID.topicID.groupID.spaceID.spaceID == "s-1")
    }

    /// Guard: an address that cannot be built fails before the network.
    @Test(arguments: [
        (String?.none, Optional("t-1"), "m-1"),
        (Optional("space/s-1"), String?.none, "m-1"),
        (Optional("s-1"), Optional("t-1"), "m-1"),
        (Optional("space/s-1"), Optional(""), "m-1"),
        (Optional("space/s-1"), Optional("t-1"), "")
    ])
    func anUnaddressableCommandSendsNothing(
        _ conversation: String?,
        _ thread: String?,
        _ id: String
    ) async throws {
        let (backend, transport) = try await connected()
        await #expect(throws: ChatError.self) {
            try await backend.send(edit(conversation: conversation, thread: thread, id: id))
        }
        await #expect(throws: ChatError.self) {
            try await backend.send(delete(conversation: conversation, thread: thread, id: id))
        }
        #expect(await transport.sent.allSatisfy { !$0.url.path.contains("_message") })
    }

    /// Guard: an empty edit is a delete in disguise; it is refused.
    @Test func anEmptyEditSendsNothing() async throws {
        let (backend, transport) = try await connected()
        await #expect(throws: ChatError.self) { try await backend.send(edit(text: "  \n")) }
        #expect(await transport.bodies("/api/edit_message").isEmpty)
    }

    @Test func aFailedCallThrows() async throws {
        let (backend, _) = try await connected(failure: URLError(.timedOut))
        await #expect(throws: ChatError.self) { try await backend.send(edit()) }
        await #expect(throws: ChatError.self) { try await backend.send(delete()) }
    }
}
