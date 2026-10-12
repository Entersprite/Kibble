import Foundation
import Testing
@testable import ChatKit

struct ConversationActionTests {
    @Test(arguments: [ConversationAction.markUnread, .hide, .block, .leave, .delete])
    func commandsHaveStableFrames(_ action: ConversationAction) throws {
        let command = ChatCommand.conversationAction(conversationID: Conversation.ID("dm/a"), action: action)
        try expectWireStable(command, golden: "command-conversationAction-" + action.wire)
    }

    @Test func eventsHaveStableFrames() throws {
        try expectWireStable(
            ChatEvent.conversationRemoved(conversationID: Conversation.ID("dm/a"), historyBefore: nil),
            golden: "event-conversationRemoved"
        )
        try expectWireStable(
            ChatEvent.conversationUnreadMarkChanged(conversationID: Conversation.ID("dm/a"), at: nil),
            golden: "event-conversationUnreadMarkChanged"
        )
    }

    @Test func unknownActionRoundTripsAndIsUnavailable() throws {
        let json = #"{"action":"archive","conversationID":"dm/a","type":"conversationAction"}"#
        let decoded = try Wire.decode(ChatCommand.self, from: json)
        #expect(decoded == .conversationAction(
            conversationID: Conversation.ID("dm/a"),
            action: .unknown("archive")
        ))
        #expect(try Wire.json(decoded) == json)
        #expect(!Capabilities().supports(.unknown("archive")))
    }

    @Test func absentCapabilitiesAreOff() throws {
        let caps = try Wire.decode(Capabilities.self, from: "{}")
        #expect(!caps.canOpenDirectConversations)
        #expect(try Wire.decode(
            Capabilities.self,
            from: Wire.json(Capabilities(canOpenDirectConversations: true))
        )
        .canOpenDirectConversations)
        for action in [ConversationAction.markUnread, .hide, .block, .leave, .delete] {
            #expect(!caps.supports(action))
        }
    }
}
