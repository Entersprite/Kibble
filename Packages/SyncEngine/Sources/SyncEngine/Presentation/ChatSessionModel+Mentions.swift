import ChatKit
import Foundation

// MARK: - The Mentions row

/// The sidebar's Mentions row and the pane behind it (the mentions-list spec
/// §4). Split out of `ChatSessionModel.swift` for `file_length`, which is why
/// `selected`, `messages`, `typing`, `conversationWatchers` and `historyTask`
/// are `internal` there.
public extension ChatSessionModel {
    /// Shows the Mentions list, and **leaves no conversation selected.**
    /// That is the whole guarantee that viewing the list reads nothing:
    /// auto-mark-read needs a selection and that selection's message
    /// observation, and this drops both. A mark already scheduled for the
    /// conversation that was open stays scheduled, as it does when switching
    /// conversations, because it covers what was on screen.
    func showMentions() {
        guard !showingMentions else { return }
        showingMentions = true
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
    }

    /// Opens a mention: selects its conversation, then asks the transcript to
    /// scroll to the message. The message is in the store, which is how it
    /// reached the list, so it is in the transcript once the selection's
    /// observation delivers. Marking read then happens as it always does on
    /// viewing.
    func open(conversation: Conversation.ID, message: Message.ID) {
        select(conversation)
        scrollTarget = message
    }
}
