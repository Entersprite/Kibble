import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// The per-conversation gate as the window applies it (Review Focus 2,
/// threads spec §5): a Meet chat (world field 27 false) gets no thread
/// action, so no mark and no "Reply in Thread", even on a backend with threads.
@MainActor
struct ThreadGateTests {
    private func threads() -> ThreadActions {
        ThreadActions(
            open: { _ in }, close: {}, sendReply: { _ in }, setFollowed: { _ in },
            markUnread: { _ in }, showList: {}, openItem: { _, _ in }
        )
    }

    private func window(selecting conversation: Conversation) -> ChatWindow {
        ChatWindow(
            state: ChatSceneState(conversations: [conversation], selected: conversation.id),
            actions: ChatSceneActions(threads: threads())
        )
    }

    private func message(in conversation: Conversation) -> Message {
        Message(
            id: Message.ID("m-1"), conversationID: conversation.id, threadID: MessageThread.ID("t-1"),
            sender: Member.ID("u-2"), text: "hello", createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func aConversationWithRepliesOffersTheMarkAndReplyInThread() {
        let space = Conversation(
            id: Conversation.ID("space/s-1"), kind: .space, title: "Deploys", repliesEnabled: true
        )
        let window = window(selecting: space)
        #expect(window.offeredThreadActions != nil)
        #expect(window.ownHandlers?.items(for: message(in: space))?.replyInThread != nil)
    }

    @Test func aMeetChatOffersNeither() {
        let meet = Conversation(id: Conversation.ID("space/m-1"), kind: .meetChat, title: "Standup")
        let window = window(selecting: meet)
        #expect(window.offeredThreadActions == nil)
        #expect(window.ownHandlers?.items(for: message(in: meet))?.replyInThread == nil)
    }

    private let space = Conversation(
        id: Conversation.ID("space/s-1"), kind: .space, title: "Deploys", repliesEnabled: true
    )
    private let meet = Conversation(id: Conversation.ID("space/m-1"), kind: .meetChat, title: "Standup")

    private func split(_ conversation: Conversation, panel: Bool, sidebarShown: Bool = true) -> ThreadSplit {
        let thread = MessageThread(id: MessageThread.ID("t-1"), conversationID: conversation.id)
        let state = ChatSceneState(
            conversations: [conversation], selected: conversation.id,
            threads: ThreadSceneState(
                panel: panel ? ThreadPanelState(thread: thread, conversationTitle: "Deploys") : nil
            )
        )
        let window = ChatWindow(state: state, actions: ChatSceneActions(threads: threads()))
        return ThreadSplit(
            state: state, actions: window.actions, threads: window.offeredThreadActions,
            own: { _ in nil }, editing: nil, dropStage: nil,
            share: .constant(ThreadSplitLayout.initialShare), title: conversation.title ?? "",
            subtitle: "", sidebarShown: sidebarShown
        )
    }

    /// The split is always applied (`ThreadSplit`'s identity rule), so the
    /// gate lives in its presentation: a panel where the conversation offers
    /// no replies (a Meet chat, or any before the first world load after the
    /// v13 upgrade) is not presented. Whether the panel shows is a
    /// screenshot's question; this pins only what it is asked.
    @Test func thePanelIsPresentedOnlyWithThreadActionsAndAPanel() {
        #expect(split(space, panel: true).isPresented)
        #expect(!split(space, panel: false).isPresented)
        #expect(!split(meet, panel: true).isPresented)
    }

    /// The split draws the conversation's title only where it knows where to
    /// put it (session 63): beside a presented panel, with the sidebar shown.
    /// Collapsed, AppKit's title starts past the window's buttons. Whether
    /// the hand-over is invisible is a render's question; this pins only when
    /// it happens.
    @Test func theSplitDrawsTheTitleOnlyBesideAPanelWithTheSidebarShown() {
        #expect(split(space, panel: true).ownsTitle)
        #expect(!split(space, panel: false).ownsTitle)
        #expect(!split(meet, panel: true).ownsTitle)
        #expect(!split(space, panel: true, sidebarShown: false).ownsTitle)
    }
}
