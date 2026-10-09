import ChatKit
import Foundation

/// One thread's summary read from the store now, for a caller outside this
/// package that decides one arrival at a time: `NotificationCoordinator`
/// (threads spec §4.3). A view takes `threads.summaries` instead, observed.
public extension ChatSessionModel {
    /// `ChatStore.thread(_:in:)` on this session's store, so it can never read
    /// a previous account's. `nil` when the store holds nothing of the thread
    /// or the read fails; a reply then counts as not followed, so a mention
    /// still notifies and nothing else does.
    func storedThread(_ thread: MessageThread.ID, in conversation: Conversation.ID) -> MessageThread? {
        try? store.thread(thread, in: conversation)
    }
}
