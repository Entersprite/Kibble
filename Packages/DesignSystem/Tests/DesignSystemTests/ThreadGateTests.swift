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

    /// The inspector is always applied (`ThreadInspector`'s identity rule),
    /// so the gate lives in its presentation: a panel where the conversation
    /// offers no replies (a Meet chat, or any before the first world load
    /// after the v13 upgrade) is not presented. Whether the inspector shows
    /// is a screenshot's question; this pins only what it is asked.
    @Test func theInspectorIsPresentedOnlyWithThreadActionsAndAPanel() {
        let space = Conversation(
            id: Conversation.ID("space/s-1"), kind: .space, title: "Deploys", repliesEnabled: true
        )
        let meet = Conversation(id: Conversation.ID("space/m-1"), kind: .meetChat, title: "Standup")
        func inspector(_ conversation: Conversation, panel: Bool) -> ThreadInspector {
            let thread = MessageThread(id: MessageThread.ID("t-1"), conversationID: conversation.id)
            let state = ChatSceneState(
                conversations: [conversation], selected: conversation.id,
                threads: ThreadSceneState(
                    panel: panel ? ThreadPanelState(thread: thread, conversationTitle: "Deploys") : nil
                )
            )
            let window = ChatWindow(state: state, actions: ChatSceneActions(threads: threads()))
            return ThreadInspector(
                state: state, actions: window.actions, threads: window.offeredThreadActions,
                own: { _ in nil }, editing: nil
            )
        }
        #expect(inspector(space, panel: true).isPresented)
        #expect(!inspector(space, panel: false).isPresented)
        #expect(!inspector(meet, panel: true).isPresented)
    }
}
