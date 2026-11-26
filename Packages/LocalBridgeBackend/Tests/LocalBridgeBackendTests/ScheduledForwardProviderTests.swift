import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@Suite(.timeLimit(.minutes(1)))
struct ScheduledForwardProviderTests {
    @Test func scheduledForwardVerifiesTheSourceAndSurvivesAnEmptyCaption() async throws {
        let original = ForwardTransport()
        let transport = ScheduledMessageTransport(forwardSource: original)
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        let source = try #require(await ChannelEventMapping.domainMessage(original.original))
        var preview = MessageQuote(message: source)
        preview.text = "Client preview does not go on the wire"
        let body = ComposedMessage(text: "Comment", content: MessageContent(forwardSource: preview))
        let destination = Conversation.ID("space/a")
        let time = Date(timeIntervalSince1970: 2_500_000_000)
        let queue = try await backend.scheduleMessage(in: destination, thread: nil, body: body, at: time)
        #expect(queue.isForward == true && queue.canEditBody)
        #expect(queue.body.content?.forwardSource == nil)
        let reference = try #require(await transport.createdReference)
        let originalID = await original.original.id
        #expect(reference.id == originalID && reference.referenceType == 2)
        #expect(reference.createTime == 2_000_000 && !reference.hasText)

        let edited = try await backend.editScheduledMessage(queue.id, body: ComposedMessage(text: ""))
        #expect(edited.body.text.isEmpty && edited.isForward == true && edited.deliveryTime == time)
        try await backend.sendScheduledMessageNow(queue.id)
        let sent = try #require(await transport.deliveredReference)
        #expect(sent.id == originalID && sent.referenceType == 2 && sent.createTime == reference.createTime)
        #expect(try await backend.scheduledMessages(after: nil).messages.isEmpty)

        await original.deleteOriginal()
        await #expect(throws: ChatError.self) {
            try await backend.scheduleMessage(in: destination, thread: nil, body: body, at: time)
        }
        #expect(await transport.writes == ["create_unsent_message", "update_unsent_message", "create_topic"])
        await backend.disconnect()
    }
}
