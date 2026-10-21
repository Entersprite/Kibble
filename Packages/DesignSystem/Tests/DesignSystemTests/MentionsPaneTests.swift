import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// The Mentions pane's pure half (the mentions-list spec §4): the item
/// mapping, the badge, the states and the footer.
struct MentionsPaneTests {
    private let me = Member.ID("users/me")
    private let alice = Member(id: Member.ID("users/alice"), kind: .human, displayName: "Alice Adams")
    private let space = Conversation(id: Conversation.ID("space:1"), kind: .space, title: "price-engine")

    private func item(isUnread: Bool = true) -> MentionItem {
        let message = Message(
            id: Message.ID("m:1"), conversationID: space.id, threadID: MessageThread.ID("t"),
            sender: alice.id, text: "@Me see this", createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            mentions: [Mention(target: .user(me), start: 0, length: 3)]
        )
        return MentionItem(
            message: message, conversation: space, isUnread: isUnread, directory: [alice.id: alice], me: me
        )
    }

    @Test func anItemCarriesTheDisplayTitleTheSenderAndTheMessage() {
        let item = item()
        #expect(item.conversationTitle == "price-engine")
        #expect(item.senderName == "Alice Adams")
        #expect(item.id == Message.ID("m:1"))
        #expect(item.conversationID == space.id)
        #expect(item.text == "@Me see this")
        #expect(item.mentions == [Mention(target: .user(me), start: 0, length: 3)])
        #expect(item.createdAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(item.isUnread)
    }

    /// A DM has no server title; the item uses the same derivation the sidebar does.
    @Test func aDirectMessagesItemIsTitledAfterTheOtherPerson() {
        let dm = Conversation(id: Conversation.ID("dm:1"), kind: .directMessage, members: [me, alice.id])
        let message = Message(
            id: Message.ID("m:2"), conversationID: dm.id, threadID: MessageThread.ID("t"),
            sender: alice.id, text: "@all", createdAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        let item = MentionItem(
            message: message, conversation: dm, isUnread: false, directory: [alice.id: alice], me: me
        )
        #expect(item.conversationTitle == "Alice Adams")
    }

    @Test func theBadgeIsTheUnreadCountAndNothingAtZero() {
        #expect(MentionsPresentation.badge(unread: 0) == nil)
        #expect(MentionsPresentation.badge(unread: 3) == "3")
    }

    @Test func thePaneSaysLookingOnlyWhileARunIsGoingAndNothingIsListedYet() {
        #expect(MentionsPresentation.content(items: [], status: MentionsStatus(running: true)) == .looking)
        #expect(MentionsPresentation.content(items: [], status: MentionsStatus()) == .empty)
        #expect(
            MentionsPresentation.content(items: [item()], status: MentionsStatus(running: true)) == .items
        )
        #expect(MentionsPresentation.lookingText == "Looking for mentions…")
        #expect(MentionsPresentation.emptyText == "No mentions in the last 30 days")
    }

    @Test func theFooterCountsTheConversationsThatCouldNotBeChecked() {
        #expect(MentionsPresentation.footer(MentionsStatus()) == nil)
        #expect(
            MentionsPresentation.footer(MentionsStatus(failedConversations: 1))
                == "Couldn't check 1 conversation"
        )
        #expect(
            MentionsPresentation.footer(MentionsStatus(failedConversations: 4))
                == "Couldn't check 4 conversations"
        )
    }

    /// A native list: one row per mention, selecting a row opens nothing,
    /// and Return opens the selected one, as a double-click does.
    @MainActor
    @Test func returnOpensTheSelectedMentionInANativeList() throws {
        let first = item()
        let message = Message(
            id: Message.ID("m:2"), conversationID: space.id, threadID: MessageThread.ID("t"),
            sender: alice.id, text: "@all", createdAt: Date(timeIntervalSince1970: 1_790_000_100)
        )
        let second = MentionItem(
            message: message, conversation: space, isUnread: false, directory: [alice.id: alice], me: me
        )
        var opened: [Message.ID] = []
        let pane = try HostedList(MentionsPane(items: [first, second], status: MentionsStatus(), me: me) {
            opened.append($1)
        })
        defer { pane.close() }
        #expect(pane.selectableRows.count == 2)
        try pane.select(row: pane.selectableRows[1])
        #expect(opened.isEmpty)
        try pane.pressReturn()
        #expect(opened == [Message.ID("m:2")])
        #expect(PaneSelection.single([first.id, second.id], in: [first, second]) == nil)
    }

    @Test func theSidebarSelectionIsMentionsWhileShowingThemAndTheConversationOtherwise() {
        var state = ChatSceneState(selected: Conversation.ID("dm:1"))
        #expect(state.sidebarSelection == .conversation(Conversation.ID("dm:1")))
        state.selected = nil
        state.showingMentions = true
        #expect(state.sidebarSelection == .mentions)
        #expect(ChatSceneState().sidebarSelection == nil)
    }
}
