import Foundation
import Testing
@testable import ChatKit

struct OutgoingForwardContentTests {
    @Test func forwardReferenceSurvivesTheCommandWireAndNeedsItsOwnCapability() throws {
        let source = Message(
            id: .init("source"),
            conversationID: .init("source-chat"),
            threadID: .init("thread"),
            sender: .init("author"),
            text: "Original",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let content = MessageContent(forwardSource: MessageQuote(message: source))
        let command = ChatCommand.sendMessage(
            conversationID: .init("destination"),
            threadID: nil,
            text: "",
            localID: "operation",
            content: content
        )
        #expect(try Wire.decode(ChatCommand.self, from: Wire.json(command)) == command)
        #expect(!content.isEmpty)
        #expect(try Wire.decode(MessageContent.self, from: "{}").forwardSource == nil)
        #expect(throws: ChatError.self) { try command.validateMessageContent(capabilities: Capabilities()) }
        try command.validateMessageContent(capabilities: Capabilities(extendedFlags: ["forwardMessages"]))
        #expect(throws: ChatError.self) {
            try ChatCommand.editMessage(
                id: source.id,
                text: "Edited",
                conversationID: source.conversationID,
                content: content
            )
            .validateMessageContent(
                capabilities: Capabilities(extendedFlags: ["forwardMessages"])
            )
        }
    }
}
