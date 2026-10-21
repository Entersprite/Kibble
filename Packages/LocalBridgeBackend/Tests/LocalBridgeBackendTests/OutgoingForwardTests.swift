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
}
