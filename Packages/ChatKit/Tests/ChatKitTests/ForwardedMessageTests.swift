import Foundation
import Testing
@testable import ChatKit

struct ForwardedMessageTests {
    @Test func forwardedSnapshotSurvivesTheEventWireWithoutChangingOuterText() throws {
        let original = Message(
            id: .init("source"), conversationID: .init("elsewhere"), threadID: .init("thread"),
            sender: .init("author"), text: "Original", createdAt: Date(timeIntervalSince1970: 1)
        )
        let outer = Message(
            id: .init("received"), conversationID: .init("destination"), threadID: .init("outer-thread"),
            sender: .init("forwarder"), text: "Comment", createdAt: Date(timeIntervalSince1970: 2),
            content: MessageContent(forwarded: ForwardedMessage(
                source: MessageQuote(message: original), senderName: "Alex Example",
                formatting: [MessageFormat(style: "futureStyle", start: 0, length: 8)]
            ))
        )
        let event = ChatEvent.messageReceived(outer)
        #expect(try Wire.decode(ChatEvent.self, from: Wire.json(event)) == event)
        #expect(outer.content?.forwarded?.message.text == "Original")
        #expect(outer.content?.forwarded?.message.content?.formatting.first?.style == "futureStyle")
        #expect(try Wire.decode(MessageContent.self, from: "{}").forwarded == nil)
        let sourceJSON = try Wire.json(MessageQuote(message: original))
        let sparse = "{\"source\":\(sourceJSON),\"future\":{\"key\":true}}"
        let decoded = try Wire.decode(ForwardedMessage.self, from: sparse)
        #expect(decoded.attachments.isEmpty && decoded.formatting.isEmpty && decoded.links.isEmpty)
        #expect(throws: ChatError.self) {
            try outer.content?.validate(
                text: outer.text,
                conversation: outer.conversationID,
                capabilities: .init()
            )
        }
    }
}
