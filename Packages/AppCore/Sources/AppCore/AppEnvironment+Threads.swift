import ChatKit
import DesignSystem
import Foundation
import SyncEngine

/// Threads, as the window sees them (threads spec §5): the model's
/// `ThreadSessionState` mapped into `ThreadSceneState`, and the model's thread
/// methods as `ThreadActions`.
extension AppEnvironment {
    func threadScene(of model: ChatSessionModel) -> ThreadSceneState {
        let threads = model.threads
        let conversations = Dictionary(
            model.conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        return ThreadSceneState(
            summaries: threads.summaries,
            panel: panel(of: model, conversations: conversations),
            items: threads.followed.compactMap { followed in
                conversations[followed.root.conversationID].map { conversation in
                    ThreadListItem(
                        root: followed.root, thread: followed.thread, conversation: conversation,
                        directory: model.directory, me: model.me
                    )
                }
            },
            showingList: threads.showingList,
            unreadCount: threads.unreadCount,
            unreadConversations: threads.unreadConversations
        )
    }

    /// The open thread's panel, in the selected conversation. A thread with no
    /// stored summary yet (opened from "Reply in Thread") is one message.
    private func panel(
        of model: ChatSessionModel, conversations: [Conversation.ID: Conversation]
    ) -> ThreadPanelState? {
        guard let open = model.threads.openThread, let selected = model.selected,
              let conversation = conversations[selected]
        else { return nil }
        return ThreadPanelState(
            thread: model.threads.summaries[open]
                ?? MessageThread(id: open, conversationID: selected, replyCount: 1),
            conversationTitle: Display.title(of: conversation, directory: model.directory, me: model.me),
            messages: model.threads.messages,
            scrollTarget: model.threads.scrollTarget,
            followPending: model.threads.followPending,
            stagedAttachments: Self.composerAttachments(model.threadStagedAttachments)
        )
    }

    /// Offered only while a session runs on a backend with threads.
    var threadActions: ThreadActions? {
        guard runningModel?.capabilities.supportsThreads == true else { return nil }
        return ThreadActions(
            open: { [weak self] in self?.runningModel?.openThread($0) },
            close: { [weak self] in self?.runningModel?.closeThread() },
            sendReply: { [weak self] in self?.runningModel?.sendReply($0) },
            setFollowed: { [weak self] in self?.runningModel?.setFollowed($0) },
            markUnread: { [weak self] in self?.runningModel?.markThreadUnread(from: $0) },
            showList: { [weak self] in self?.runningModel?.showThreads() },
            openItem: { [weak self] conversation, thread in
                self?.runningModel?.openThreadItem(thread, in: conversation)
            },
            attachments: composerAttachmentActions(in: .openThread)
        )
    }
}
