import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// What the Unread pane lists and says in each state, without drawing it.
struct UnreadPresentationTests {
    private let design = Conversation(id: .init("design"), kind: .space, title: "Design Team")
    private let launch = Conversation(id: .init("launch"), kind: .space, title: "Launch Team")
    private let muted = Conversation(id: .init("muted"), kind: .space, title: "Announcements")

    private func message(_ id: String, in conversation: Conversation, reply: Bool = false) -> Message {
        Message(
            id: .init(id), conversationID: conversation.id, threadID: .init("topic-\(id)"),
            sender: .init("person"), text: id, createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isReply: reply
        )
    }

    private func state(_ filter: UnreadFilter) -> ChatSceneState {
        var state = ChatSceneState(conversations: [launch, design, muted])
        state.unread.showing = true
        state.unread.filter = filter
        state.unread.badgeConversations = [design.id, launch.id]
        state.unread.conversationsWithUnread = [design.id, launch.id, muted.id]
        state.unread.messages = [
            message("checklist", in: launch), message("notes", in: design),
            message("feedback", in: design, reply: true), message("news", in: muted)
        ]
        return state
    }

    @Test func badgeOnlyListsMainMessagesOfBadgedConversationsByName() {
        let groups = UnreadPresentation.groups(state(.badgeOnly))
        #expect(groups.map(\.title) == ["Design Team", "Launch Team"])
        #expect(groups.map { $0.messages.map(\.id.rawValue) } == [["notes"], ["checklist"]])
    }

    @Test func allAddsRepliesAndUnbadgedConversations() {
        let groups = UnreadPresentation.groups(state(.all))
        #expect(groups.map(\.title) == ["Announcements", "Design Team", "Launch Team"])
        #expect(groups[1].messages.map(\.id.rawValue) == ["notes", "feedback"])
    }

    @Test func aMessageWhoseConversationIsGoneIsNotListed() {
        var state = state(.all)
        state.conversations = [design]
        #expect(UnreadPresentation.groups(state).map(\.id) == [design.id])
    }

    @Test func contentFollowsTheFilterAndTheHistory() {
        var state = state(.badgeOnly)
        #expect(UnreadPresentation.content(state, groups: UnreadPresentation.groups(state)) == .rows)

        state.unread.badgeConversations = []
        #expect(UnreadPresentation.content(state, groups: []) == .nothingBadged(others: true))
        state.unread.conversationsWithUnread = []
        state.unread.messages = []
        #expect(UnreadPresentation.content(state, groups: []) == .nothingBadged(others: false))

        state.unread.filter = .all
        #expect(UnreadPresentation.content(state, groups: []) == .caughtUp)
        state.unread.isLoading = true
        #expect(UnreadPresentation.content(state, groups: []) == .looking)
        state.unread.isLoading = false
        state.unread.messages = nil
        #expect(UnreadPresentation.content(state, groups: []) == .looking)
        state.unread.historyFailed = true
        #expect(UnreadPresentation.content(state, groups: []) == .failed)

        state.unread.historyFailed = false
        state.unread.messages = []
        state.unread.conversationsWithUnread = [muted.id]
        #expect(UnreadPresentation.content(state, groups: []) == .unavailable)
    }

    @Test func aPartFailedCheckOffersRetryBelowItsRows() {
        var state = state(.all)
        let groups = UnreadPresentation.groups(state)
        #expect(!UnreadPresentation.showsRetryFooter(state, groups: groups))
        state.unread.historyFailed = true
        #expect(UnreadPresentation.showsRetryFooter(state, groups: groups))
        #expect(!UnreadPresentation.showsRetryFooter(state, groups: []))
        state.unread.isLoading = true
        #expect(!UnreadPresentation.showsRetryFooter(state, groups: groups))
    }

    @Test func markAllIsOfferedWhileTheFilterHasSomethingUnread() {
        var state = state(.badgeOnly)
        #expect(UnreadPresentation.canMarkAll(state))
        state.unread.messages = []
        #expect(UnreadPresentation.canMarkAll(state))
        state.unread.badgeConversations = []
        #expect(!UnreadPresentation.canMarkAll(state))
        state.unread.readOnThisDevice = [message("notes", in: design)]
        #expect(!UnreadPresentation.canMarkAll(state))
        state.unread.filter = .all
        #expect(UnreadPresentation.canMarkAll(state))
    }

    @MainActor @Test func theWindowToolbarCarriesTheControlsOnlyWhileUnreadIsShown() {
        var actions = ChatSceneActions()
        var state = state(.badgeOnly)
        #expect(ChatWindow(state: state, actions: actions).unreadToolbarActions == nil)
        actions.unread = UnreadActions(show: {}, retry: {})
        #expect(ChatWindow(state: state, actions: actions).unreadToolbarActions != nil)
        state.browser.page = "space"
        #expect(ChatWindow(state: state, actions: actions).unreadToolbarActions == nil)
        state.browser.page = nil
        state.unread.showing = false
        #expect(ChatWindow(state: state, actions: actions).unreadToolbarActions == nil)
    }

    @Test func aMessageWithNoWordsIsNamedByWhatItCarries() {
        var empty = message("empty", in: design)
        empty.text = ""
        #expect(UnreadPresentation.preview(of: empty) == "Message")
        #expect(UnreadPresentation.preview(of: message("words", in: design)) == "words")
    }
}
