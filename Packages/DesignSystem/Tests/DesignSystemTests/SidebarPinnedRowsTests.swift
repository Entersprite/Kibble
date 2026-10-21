import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// The rows above the conversations, which never scroll, and how each of the
/// sidebar's two lists turns a selection into an action.
@MainActor
struct SidebarPinnedRowsTests {
    private final class Calls {
        var log: [String] = []
    }

    private let id = Conversation.ID("dm/1")

    private func threads(_ calls: Calls = Calls()) -> ThreadActions {
        ThreadActions(
            open: { _ in }, close: {}, sendReply: { _ in }, setFollowed: { _ in },
            markUnread: { _ in }, showList: { calls.log.append("threads") }, openItem: { _, _ in }
        )
    }

    @Test func searchMentionsAndThreadsInThatOrderWhenAllAreOffered() {
        let actions = ChatSceneActions(showMentions: {}, threads: threads(), search: .inert)
        #expect(SidebarPinned.rows(actions) == [.search, .mentions, .threads])
    }

    /// The same gate as Edit › Search…: a backend that cannot search gets no row.
    @Test func searchIsDrawnOnlyWhereTheHostOffersIt() {
        let actions = ChatSceneActions(showMentions: {}, threads: threads())
        #expect(SidebarPinned.rows(actions) == [.mentions, .threads])
    }

    @Test func nothingIsPinnedWhereNothingIsOffered() {
        #expect(SidebarPinned.rows(ChatSceneActions()).isEmpty)
    }

    @Test func thePinnedListSelectsMentionsOrThreadsAndNeverAConversation() {
        #expect(SidebarPinned.pinnedSelection(ChatSceneState(showingMentions: true)) == .mentions)
        #expect(
            SidebarPinned.pinnedSelection(ChatSceneState(threads: ThreadSceneState(showingList: true)))
                == .threads
        )
        #expect(SidebarPinned.pinnedSelection(ChatSceneState(selected: id)) == nil)
    }

    @Test func theConversationListSelectsAConversationAndNeverAPinnedRow() {
        #expect(SidebarPinned.conversationSelection(ChatSceneState(selected: id)) == .conversation(id))
        #expect(SidebarPinned.conversationSelection(ChatSceneState(showingMentions: true)) == nil)
        #expect(
            SidebarPinned.conversationSelection(
                ChatSceneState(selected: id, threads: ThreadSceneState(showingList: true))
            ) == nil
        )
    }

    /// The list draws its own badge, and none at zero: Mentions and Threads
    /// hand it nothing when nothing is unread.
    @Test func aBadgeOnlyWhereSomethingIsUnread() {
        #expect(SidebarPinned.badge(MentionsPresentation.badge(unread: 0)) == nil)
        #expect(SidebarPinned.badge(ThreadsPresentation.badge(unread: 0)) == nil)
        #expect(SidebarPinned.badge(MentionsPresentation.badge(unread: 3)) != nil)
    }

    /// A row's picture is the size the sidebar draws its symbols at, for each
    /// of the person's sidebar icon sizes, so names line up with the pinned
    /// rows' and rows grow and shrink together.
    @Test func rowPicturesFollowTheSidebarIconSize() {
        #expect(SidebarRowPicture.diameter(.small) == 16)
        #expect(SidebarRowPicture.diameter(.medium) == 20)
        #expect(SidebarRowPicture.diameter(.large) == 24)
    }

    @Test func choosingARowAsksForWhatItShows() {
        let calls = Calls()
        let actions = ChatSceneActions(
            select: { calls.log.append("select \($0.rawValue)") },
            showMentions: { calls.log.append("mentions") },
            threads: threads(calls)
        )
        SidebarPinned.choose(.mentions, actions: actions)
        SidebarPinned.choose(.threads, actions: actions)
        SidebarPinned.choose(.conversation(id), actions: actions)
        SidebarPinned.choose(nil, actions: actions)
        #expect(calls.log == ["mentions", "threads", "select dm/1"])
    }
}
