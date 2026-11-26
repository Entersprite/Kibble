import ChatKit
import Testing
@testable import DesignSystem

struct ConversationActionMenuTests {
    private let supported = Capabilities(
        canMarkUnread: true, canHideConversations: true, canBlockConversations: true,
        canLeaveConversations: true, canDeleteConversations: true
    )

    @Test(arguments: [Conversation.Kind.directMessage, .appDirectMessage, .groupDirectMessage, .space])
    func menuOffersTheActionsForItsKind(_ kind: Conversation.Kind) {
        let conversation = Conversation(id: Conversation.ID("opaque"), kind: kind)
        let items = ConversationMenu.items(
            for: conversation,
            state: ChatSceneState(),
            offers: .init(conversationActions: supported)
        )
        let tail: [ConversationMenu.Item] = kind == .directMessage || kind == .appDirectMessage
            ? [.action(.hide), .action(.block), .action(.delete)]
            : [.action(.leave), .action(.hide), .action(.block)]
        #expect(items == [.action(.markUnread)] + tail)
    }

    @Test(arguments: [Conversation.Kind.meetChat, .unknown("future")])
    func unknownAndMeetKindsOfferNone(_ kind: Conversation.Kind) {
        let items = ConversationMenu.items(
            for: Conversation(id: Conversation.ID("opaque"), kind: kind),
            state: ChatSceneState(),
            offers: .init(conversationActions: supported)
        )
        #expect(items.isEmpty)
    }

    @Test func unreadIsOfferedEvenWhenReadReceiptsAreWithheld() {
        let id = Conversation.ID("opaque")
        let items = ConversationMenu.items(
            for: Conversation(id: id, kind: .directMessage),
            state: ChatSceneState(receiptsWithheld: [id]),
            offers: .init(conversationActions: supported)
        )
        #expect(items.first == .action(.markUnread))
    }

    /// The alert's title names the conversation; its message explains,
    /// without repeating the name.
    @Test func aConfirmationNamesTheConversationItActsOn() {
        #expect(ConversationAction.leave.confirmationTitle(named: "Deploys") == "Leave “Deploys”?")
        #expect(ConversationAction.block.confirmationTitle(named: "Ada Lovelace") == "Block “Ada Lovelace”?")
        #expect(ConversationAction.delete
            .confirmationTitle(named: "Ada Lovelace") == "Delete “Ada Lovelace”?")
        let pending = PendingConversationAction(
            conversation: Conversation.ID("dm/1"), action: .delete, title: "Ada Lovelace",
            perform: { _, _ in }
        )
        #expect(pending.confirmationTitle == "Delete “Ada Lovelace”?")
        for action in [ConversationAction.leave, .block, .delete] {
            #expect(!action.confirmationMessage.isEmpty)
            #expect(!action.confirmationMessage.contains("Ada"))
        }
    }

    @Test func destructiveActionsNeedConfirmation() {
        #expect(ConversationAction.block.needsConfirmation)
        #expect(ConversationAction.leave.needsConfirmation)
        #expect(ConversationAction.delete.needsConfirmation)
        #expect(!ConversationAction.hide.needsConfirmation)
        #expect(!ConversationAction.markUnread.needsConfirmation)
    }
}
