import ChatKit
import Foundation

// MARK: - The thread panel and the Threads list

/// The thread panel and the Threads list (threads spec §4.3), on the model's
/// one property for threads, `threads`. Its own file for
/// `ChatSessionModel.swift`'s `file_length`; viewing a thread marks it read in
/// `+ThreadMarkRead.swift`.
///
/// Gated on `Capabilities.supportsThreads` where an action would otherwise
/// reach the backend. No action reads `Conversation.repliesEnabled`: the view
/// offers them only where replies are enabled, and a notification's click on
/// a reply must open its panel even before the first world load after the
/// migration has filled that flag. What the window draws does read it
/// (`isThreadPanelShown`).
public extension ChatSessionModel {
    /// Whether the window draws the panel: a thread is open, in a conversation
    /// that offers replies (`ChatWindow.offeredThreadActions`' gate). A panel
    /// opened before the first world load after the v13 upgrade is held but
    /// not drawn, so it is not marked read and is not on screen for a reply's
    /// notification (session 58).
    var isThreadPanelShown: Bool {
        guard threads.openThread != nil, let selected else { return false }
        return conversations.first { $0.id == selected }?.repliesEnabled == true
    }

    /// Opens the panel on one of the selected conversation's threads: observes
    /// its messages, the first included, and fetches it, because a history
    /// page carries at most 50 replies a thread. Opening the thread already
    /// shown does nothing; opening another replaces it.
    func openThread(_ thread: MessageThread.ID) {
        guard capabilities.supportsThreads, let selected, threads.openThread != thread else { return }
        closeThread()
        threads.openThread = thread
        threads.work.panelTasks = [
            observe(store.observeThread(thread, in: selected)) { [weak self] in
                self?.threads.messages = $0
                self?.markOpenThreadReadIfNeeded()
            },
            // With the observation, so closing the panel cancels a fetch
            // nobody waits for, and `stop()` one that would answer into an
            // erased store (`SyncEngine.loadThread`).
            Task { [engine] in await engine.requestThread(thread, in: selected) }
        ]
    }

    /// Closes the panel. A mark already scheduled for the thread stays
    /// scheduled, as one for a conversation does when the selection moves,
    /// because it covers what was on screen. A manual Mark as Unread's hold
    /// ends here (spec §4.3).
    func closeThread() {
        for task in threads.work.panelTasks {
            task.cancel()
        }
        threads.work.panelTasks = []
        threads.work.disarmed = nil
        threads.openThread = nil
        threads.messages = []
        threads.scrollTarget = nil
    }

    /// Sends a reply into the open thread and shows it at once.
    ///
    /// The optimistic row is `send(_:)`'s, with the same `local/` id
    /// convention, plus `isReply` and the thread's id. So it lands in the
    /// panel and **never in the transcript**, which reads top-level messages
    /// only. The echo replaces it by `localID`, as for any message. No staged
    /// files: attachments in replies are not built (spec §7).
    ///
    /// A refusal takes the row back and is recorded where errors show. Its
    /// text is not handed back: `failedDraft` belongs to the conversation's
    /// composer, and restoring a reply there would post it at the top level.
    func sendReply(_ message: ComposedMessage) {
        guard let selected, let thread = threads.openThread, capabilities.canSendMessages,
              !message.text.isEmpty else { return }
        let localID = UUID().uuidString
        let optimisticID = Message.ID("local/\(localID)")
        var undo: [StoreWrite] = []
        if let me {
            try? store.apply([.upsertMessage(Message(
                id: optimisticID, conversationID: selected, threadID: thread, sender: me,
                text: message.text, createdAt: Date(), localID: localID, mentions: message.mentions,
                isReply: true
            ))])
            // By id, never by `localID`, for `send(_:)`'s reason.
            undo = [.removeMessage(id: optimisticID)]
        }
        let command = ChatCommand.sendMessage(
            conversationID: selected, threadID: thread, text: message.text, localID: localID,
            mentions: message.mentions
        )
        // Untracked, like `send(_:)`'s, a known wart that file records.
        Task { [engine, undo] in
            await engine.submit(command, undoing: undo)
        }
    }

    /// Follows or unfollows the open thread. The toggle waits for the answer
    /// (`followPending`), so it never springs back, and one runs at a time: a
    /// second toggle while one is pending does nothing. A refusal is recorded
    /// where errors show, and the toggle keeps the stored state.
    func setFollowed(_ followed: Bool) {
        guard let selected, let thread = threads.openThread, !threads.followPending else { return }
        threads.followPending = true
        threads.work.followTask = Task { @MainActor [weak self, engine] in
            await engine.requestThreadFollowed(followed, thread: thread, in: selected)
            guard let self, !Task.isCancelled else { return }
            threads.followPending = false
            threads.work.followTask = nil
        }
    }

    /// Shows the Threads list, leaving no conversation selected
    /// (`clearSelection()`), and fetches it when the pane opens. The pane
    /// reads the store (spec §4.3), so if the fetch brings nothing it lists
    /// the threads Kibble has seen followed.
    func showThreads() {
        guard capabilities.supportsThreads, !threads.showingList else { return }
        clearSelection()
        threads.showingList = true
        threads.work.listTask?.cancel()
        threads.work.listTask = Task { [engine] in await engine.requestFollowedThreads() }
    }

    /// Opens a Threads list item: selects its conversation, scrolls the
    /// transcript to the thread's first message, as a mention opens, and opens
    /// the panel on it (spec §5.3).
    func openThreadItem(_ thread: MessageThread.ID, in conversation: Conversation.ID) {
        select(conversation)
        scrollTarget = firstMessage(of: thread, in: conversation)
        openThread(thread)
    }
}

extension ChatSessionModel {
    /// The thread's first message, for the transcript to scroll to. Read from
    /// the store at the click, one thread's messages and not the whole
    /// transcript, because the transcript's observation has not delivered the
    /// conversation yet; `nil` when it is not stored.
    func firstMessage(of thread: MessageThread.ID, in conversation: Conversation.ID) -> Message.ID? {
        let stored = (try? store.threadMessages(thread, in: conversation)) ?? []
        return stored.first { !$0.isReply }?.id
    }
}
