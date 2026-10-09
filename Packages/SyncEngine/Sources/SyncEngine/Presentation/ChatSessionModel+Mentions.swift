import ChatKit
import Foundation

// MARK: - The Mentions row

/// The sidebar's Mentions row and the pane behind it (the mentions-list spec
/// §4). Split out of `ChatSessionModel.swift` for `file_length`, which is why
/// `selected`, `messages`, `typing`, `conversationWatchers` and `historyTask`
/// are `internal` there.
public extension ChatSessionModel {
    /// Shows the Mentions list, and leaves no conversation selected
    /// (`clearSelection()`, whose doc comment is the guarantee).
    func showMentions() {
        guard !showingMentions else { return }
        clearSelection()
        showingMentions = true
    }

    /// Opens a mention: selects its conversation, then asks the transcript to
    /// scroll to the message. The message is in the store, which is how it
    /// reached the list, so it is in the transcript once the selection's
    /// observation delivers. Marking read then happens as it always does on
    /// viewing.
    ///
    /// **A reply is not in the transcript** (threads spec §5.3). For one, the
    /// transcript scrolls to its thread's first message and the panel opens on
    /// the thread at the reply. A notification's click comes here too.
    func open(conversation: Conversation.ID, message: Message.ID) {
        select(conversation)
        guard let reply = try? store.message(message), reply.isReply else {
            scrollTarget = message
            return
        }
        scrollTarget = firstMessage(of: reply.threadID, in: conversation)
        openThread(reply.threadID)
        threads.scrollTarget = message
    }
}

extension ChatSessionModel {
    /// Leaves the open conversation for a list in the sidebar, Mentions or
    /// Threads, and **leaves no conversation selected.** That is the whole
    /// guarantee that viewing a list reads nothing: auto-mark-read needs a
    /// selection and that selection's message observation, and this drops
    /// both, and the thread panel with them. A mark already scheduled for the
    /// conversation or the thread that was open stays scheduled, as it does
    /// when switching conversations, because it covers what was on screen.
    func clearSelection() {
        showingMentions = false
        threads.showingList = false
        scrollTarget = nil
        selected = nil
        markReadTrace?.selectionChanged(to: nil, in: conversations)
        messages = []
        typing = []
        for watcher in conversationWatchers {
            watcher.cancel()
        }
        conversationWatchers = []
        historyTask?.cancel()
        historyTask = nil
        closeThread()
        threads.summaries = [:]
    }
}
