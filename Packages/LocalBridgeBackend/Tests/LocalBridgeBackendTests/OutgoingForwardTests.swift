import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

actor ForwardTransport: HTTPTransport {
    var original: GChatBridgeCore.Message
    var sent: [CreateTopicRequest] = []
    init() {
        var message = GChatBridgeCore.Message()
        message.id.messageID = "source"
        message.id.parentID.topicID.topicID = "source-thread"
        message.id.parentID.topicID.groupID.dmID.dmID = "source-chat"
        message.creator.userID.id = "author"
        message.textBody = "Original"
        message.createTime = 1_000_000
        message.lastUpdateTime = 2_000_000
        original = message
    }

    func deleteOriginal() {
        original.deleteTime = 3_000_000
    }

    func addCustomEmoji(_ emoji: CustomEmojiRef) throws {
        original.textBody = emoji.displayText
        let span = MessageCustomEmoji(emoji: emoji, start: 0, length: emoji.displayText.utf16.count)
        original.annotations = try MessageContentMapping.emojiAnnotations([span], text: original.textBody)
        original.annotations[0].customEmojiMetadata.customEmoji.readToken = emoji.imageToken ?? ""
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body: Data
        switch request.url.path {
        case let path where path.contains("/mole/world"):
            body = Data(LocalBridgeBackendTests.shell(app: "DynamiteWebUi").utf8)
        case let path where path.hasSuffix("list_messages"):
            var response = ListMessagesResponse(); response.messages = [original]
            body = try response.serializedData()
        case let path where path.hasSuffix("create_topic"):
            try sent.append(CreateTopicRequest(serializedBytes: request.body ?? Data()))
            var response = CreateTopicResponse(); response.topic.id.topicID = "accepted"
            body = try response.serializedData()
        default: body = Data()
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: body)
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw CancellationError()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct OutgoingForwardTests {
    @Test func forwardUsesVerifiedSourceAndOptionalCommentAcrossConversations() async throws {
        let transport = ForwardTransport()
        let backend = try LocalBridgeBackend(
            cookies: #require(SessionCookies(header: "SID=a; OSID=b")),
            transport: transport
        )
        try await backend.connect()
        let source = try #require(await ChannelEventMapping.domainMessage(transport.original))
        for comment in ["", "My comment"] {
            try await backend.send(.sendMessage(
                conversationID: .init("space/destination"), threadID: nil, text: comment,
                localID: "forward-\(comment)",
                content: MessageContent(forwardSource: MessageQuote(message: source))
            ))
        }
        let sent = await transport.sent
        #expect(sent.count == 2 && sent.map(\.textBody) == ["", "My comment"])
        let reference = sent[0].messageInfo.replyTo
        #expect(reference.referenceType == 2)
        #expect(await reference.id == (transport.original.id))
        #expect(reference.createTime == 2_000_000)
        #expect(sent[0].groupID.spaceID.spaceID == "destination")
        let encoded = try PBLiteEncoder.encode(reference)
        #expect(encoded.arrayValue?[3].intValue == 2)
        await transport.deleteOriginal()
        await #expect(throws: ChatError.self) {
            try await backend.send(.sendMessage(
                conversationID: .init("space/destination"),
                threadID: nil,
                text: "",
                localID: "deleted",
                content: MessageContent(forwardSource: MessageQuote(message: source))
            ))
        }
        #expect(await transport.sent.count == 2)
        await backend.disconnect()
    }

    /// The echo of this session's forward shows the source it was checked
    /// against when the echo itself carries no reference; anyone else's
    /// message, and an echo that carries one, are left as they arrived.
    @Test func ownForwardEchoWithoutItsReferenceShowsTheCheckedSource() async throws {
        let transport = ForwardTransport()
        let backend = try LocalBridgeBackend(
            cookies: #require(SessionCookies(header: "SID=a; OSID=b")),
            transport: transport
        )
        try await backend.connect()
        let source = try #require(await ChannelEventMapping.domainMessage(transport.original))
        try await backend.send(.sendMessage(
            conversationID: .init("space/destination"), threadID: nil, text: "", localID: "forward-echo",
            content: MessageContent(forwardSource: MessageQuote(message: source))
        ))
        let echoed = try await backend
            .prepareChannelEvent(ChannelEvent(protobuf: Self.posted(localID: "forward-echo")))
        guard case let .messageReceived(echo)? = echoed.first else {
            Issue.record("The echo was not delivered as a message")
            return
        }
        let forwarded = try #require(echo.content?.forwarded)
        #expect(forwarded.source.id == ChatKit.Message.ID("source"))
        #expect(forwarded.source.conversation == Conversation.ID("dm/source-chat"))
        #expect(forwarded.source.thread == MessageThread.ID("source-thread"))
        #expect(forwarded.source.sender == Member.ID("author"))
        #expect(forwarded.source.text == "Original")
        #expect(echo.text.isEmpty)
        let other = try await backend.prepareChannelEvent(ChannelEvent(protobuf: Self.posted(localID: nil)))
        guard case let .messageReceived(plain)? = other.first else {
            Issue.record("The other message was not delivered")
            return
        }
        #expect(plain.content == nil)
        await backend.disconnect()
    }

    @Test func ownForwardEchoRetainsCustomEmojiFromTheVerifiedSource() async throws {
        let transport = ForwardTransport()
        let emoji = CustomEmojiRef(id: "party-id", shortcode: "party", imageToken: "source-token")
        try await transport.addCustomEmoji(emoji)
        let backend = try LocalBridgeBackend(
            cookies: #require(SessionCookies(header: "SID=a; OSID=b")), transport: transport
        )
        try await backend.connect()
        let source = try #require(await ChannelEventMapping.domainMessage(transport.original))
        try await backend.send(.sendMessage(
            conversationID: .init("space/destination"), threadID: nil, text: "", localID: "emoji-echo",
            content: MessageContent(forwardSource: MessageQuote(message: source))
        ))
        let events = try await backend
            .prepareChannelEvent(ChannelEvent(protobuf: Self.posted(localID: "emoji-echo")))
        guard case let .messageReceived(echo)? = events.first else {
            Issue.record("The forward echo was not delivered")
            return
        }
        let forwarded = try #require(echo.content?.forwarded)
        #expect(forwarded.customEmoji == source.content?.customEmoji)
        #expect(forwarded.customEmoji.first?.emoji == emoji)
        #expect(forwarded.customEmoji.first?.range(in: forwarded.source.text) != nil)
        await backend.disconnect()
    }

    private static func posted(localID: String?) -> Event {
        var message = GChatBridgeCore.Message()
        message.id.messageID = "echo-\(localID ?? "other")"
        message.id.parentID.topicID.topicID = message.id.messageID
        message.id.parentID.topicID.groupID.spaceID.spaceID = "destination"
        message.creator.userID.id = "me"
        message.createTime = 5_000_000
        if let localID {
            message.localID = localID
        }
        var event = Event()
        event.type = .messagePosted
        var body = Event.EventBody()
        body.eventType = .messagePosted
        body.messagePosted.message = message
        event.bodies = [body]
        return event
    }
}
