import Foundation
import Testing
@testable import ChatKit

/// `.editMessage` and `.deleteMessage` carry their message's address and the
/// edit's mentions (edit spec §2), and a frame from before they did still
/// decodes to the same command it always meant.
struct EditDeleteCommandTests {
    @Test func anOldEditFrameDecodesWithNoAddress() throws {
        let json = #"{"id":"m-1","text":"Corrected.","type":"editMessage"}"#
        let decoded = try Wire.decode(ChatCommand.self, from: json)
        #expect(decoded == .editMessage(id: Message.ID("m-1"), text: "Corrected."))
    }

    @Test func anOldDeleteFrameDecodesWithNoAddress() throws {
        let json = #"{"id":"m-1","type":"deleteMessage"}"#
        let decoded = try Wire.decode(ChatCommand.self, from: json)
        #expect(decoded == .deleteMessage(id: Message.ID("m-1")))
    }

    /// Guard: `mentions` is encoded only when there are some. Delete the
    /// `if !mentions.isEmpty` and this fails.
    @Test func anEditWithoutMentionsWritesNoMentionsKey() throws {
        let json = try Wire.json(ChatCommand.editMessage(id: Message.ID("m-1"), text: "x"))
        #expect(!json.contains("mentions"))
    }

    @Test func anAddressedEditRoundTripsItsMentions() throws {
        let command = ChatCommand.editMessage(
            id: Message.ID("m-1"), text: "@all x",
            conversationID: Conversation.ID("space/s-1"), threadID: MessageThread.ID("t-1"),
            mentions: [Mention(target: .all, start: 0, length: 4)]
        )
        #expect(try Wire.decode(ChatCommand.self, from: Wire.json(command)) == command)
    }
}
