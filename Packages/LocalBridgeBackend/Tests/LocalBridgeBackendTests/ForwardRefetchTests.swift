import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

private actor ForwardRefetchTransport: HTTPTransport {
    let answer: GChatBridgeCore.Message
    private(set) var readAddresses: [MessageId] = []

    init(_ answer: GChatBridgeCore.Message) {
        self.answer = answer
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body: Data
        switch request.url.path {
        case let path where path.contains("/mole/world"):
            body = Data(LocalBridgeBackendTests.shell(app: "DynamiteWebUi").utf8)
        case let path where path.hasSuffix("/get_message"):
            let read = try GetMessageRequest(serializedBytes: request.body ?? Data())
            readAddresses.append(read.messageID)
            var response = GetMessageResponse()
            response.message = answer
            body = try response.serializedData()
        default:
            body = Data()
        }
        return HTTPResponse(status: 200, headers: .init([]), body: body)
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw CancellationError()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ForwardRefetchTests {
    @Test(arguments: [true, false])
    func sparseForwardReadsTheReceivingMessageAndOnlyAcceptsItsExactSnapshot(matching: Bool) async throws {
        let outer = postedMessage()
        var full = outer
        full.replyTo.id = outer.id
        full.replyTo.id.messageID = "original"
        full.replyTo.textBody = "Original body"
        full.replyTo.referenceType = 2
        if !matching {
            full.id.parentID.topicID.groupID.spaceID.spaceID = "unrelated"
        }
        let transport = ForwardRefetchTransport(full)
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        let events = SenderEventLog(backend)
        try await backend.connect()

        let first = try await backend.prepareChannelEvent(channelPost(outer))
        guard case let .messageReceived(initial)? = first.first else {
            Issue.record("The caption did not arrive as a message")
            return
        }
        #expect(initial.text == "Comment")
        #expect(initial.content?.forwarded == nil)
        await backend.forwardRefetches[outer.id]?.value
        let updates: [ChatKit.Message] = await events.settle().compactMap {
            if case let .messageUpdated(row) = $0 {
                row
            } else {
                nil
            }
        }
        #expect(await transport.readAddresses == [outer.id])
        if matching {
            let recovered = try #require(updates.first)
            #expect(recovered.id == initial.id)
            #expect(recovered.text == "Comment")
            #expect(recovered.content?.forwarded?.source.text == "Original body")
        } else {
            #expect(updates.isEmpty)
        }
        await backend.disconnect()
    }

    @Test func plainQuotesAndCompleteForwardsDoNotRequestAnotherRead() throws {
        var plain = postedMessage()
        plain.annotations = []
        var quote = postedMessage()
        quote.replyTo.id = quote.id
        quote.replyTo.referenceType = 1
        quote.replyTo.textBody = "Quoted body"
        var full = postedMessage()
        full.replyTo.id = full.id
        full.replyTo.referenceType = 2
        full.replyTo.textBody = "Original body"
        for message in [plain, quote, full] {
            var lookups = 0
            let events = try ChannelEventMapping.chatEvents(from: channelPost(message)) { _ in lookups += 1 }
            #expect(events.count == 1)
            #expect(lookups == 0)
        }
    }

    @Test func binaryReferenceAnnotationRetainsAnOpaquePayload() throws {
        // Annotation type 28 plus a synthetic payload at field 28 that is
        // intentionally unreadable as a nested protobuf message.
        let bytes = Data([0x08, 28, 0xE2, 0x01, 0x01, 0xFF])
        let annotation = try Annotation(serializedBytes: bytes)
        #expect(annotation.type == .replyReference)
        #expect(ProtoFieldScan.payloads(ofField: 28, in: annotation.unknownFields.data) == [Data([0xFF])])
    }

    private func postedMessage() -> GChatBridgeCore.Message {
        var message = GChatBridgeCore.Message()
        message.id.parentID.topicID.groupID.spaceID.spaceID = "receiving-space"
        message.id.parentID.topicID.topicID = "receiving-thread"
        message.id.messageID = "forwarded-wrapper"
        message.creator.userID.id = "sender"
        message.createTime = 10_000_000
        message.textBody = "Comment"
        message.annotations = [PBLiteDecoder.decode(Annotation.self, from: .array([.object([
            "1": 28, "20": 1, "28": [[1, 8]]
        ])])).message]
        return message
    }

    private func channelPost(_ message: GChatBridgeCore.Message) throws -> ChannelEvent {
        var body = Event.EventBody()
        body.eventType = .messagePosted
        body.messagePosted.message = message
        var event = Event()
        event.type = .messagePosted
        event.bodies = [body]
        return try ChannelEvent(protobuf: event)
    }
}
