import ChatKit
import Testing
@testable import DesignSystem

/// The Info sheet's subtitle names what the conversation is.
struct ConversationDetailsTextTests {
    @Test func eachKindHasItsName() {
        #expect(ConversationDetailsText.kind(.directMessage) == "Direct Message")
        #expect(ConversationDetailsText.kind(.groupDirectMessage) == "Group Chat")
        #expect(ConversationDetailsText.kind(.space) == "Space")
    }

    @Test func aOneToOneChatSaysDirectMessage() {
        let details = ConversationDetails(
            conversation: Conversation(id: .init("dm"), kind: .directMessage),
            membership: .joined
        )
        #expect(ConversationDetailsText.subtitle(details).hasPrefix("Direct Message"))
    }
}
