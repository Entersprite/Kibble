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

    private func window(
        _ conversation: Conversation, panel: Bool, mentions: Bool = false, list: Bool = false
    ) -> ChatWindow {
        let thread = MessageThread(id: MessageThread.ID("t-1"), conversationID: conversation.id)
        let state = ChatSceneState(
            conversations: [conversation], selected: conversation.id, showingMentions: mentions,
            threads: ThreadSceneState(
                panel: panel ? ThreadPanelState(thread: thread, conversationTitle: "Deploys") : nil,
                showingList: list
            )
        )
        return ChatWindow(state: state, actions: ChatSceneActions(threads: threads()))
    }

    /// The thread column opens only with a panel, in a conversation that offers
    /// replies, while that conversation is on screen: a Meet chat (or any before
    /// the first world load after the v13 upgrade) never opens it, and Mentions
    /// or the Threads list taking the conversation's place collapse it. Whether
    /// AppKit collapses the split view item is the harness's question
    /// (`ThreadColumnBridge`); this pins only what it is asked.
    @Test func theThreadColumnOpensOnlyBesideItsConversation() {
        #expect(window(space, panel: true).threadColumnShown)
        #expect(!window(space, panel: false).threadColumnShown)
        #expect(!window(meet, panel: true).threadColumnShown)
        #expect(!window(space, panel: true, mentions: true).threadColumnShown)
        #expect(!window(space, panel: true, list: true).threadColumnShown)
    }
}
