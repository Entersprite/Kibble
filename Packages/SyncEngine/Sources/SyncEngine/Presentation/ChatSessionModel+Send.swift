import ChatKit
import Foundation

// MARK: - Sending, and the draft a refused send hands back

/// Split out of `ChatSessionModel.swift` to keep that file under swiftlint's
/// `file_length` ceiling, which it had reached exactly - the same reason
/// `ChatSessionModel+AutoMarkRead.swift` next door exists, and the precedent
/// `LiveChannelTests.swift` records for splitting a file rather than trimming
/// a doc comment to fit.
///
/// `failed` and `store` are declared in `ChatSessionModel.swift` without
/// `private` (plain `internal`) specifically so this extension - in a
/// different source file, where Swift's same-file `private` visibility does
/// not reach - can read and write them, exactly as `published`, `markTasks`
/// and `engine` are already spelled for `+AutoMarkRead.swift`. The public
/// surface is unchanged either way: nothing outside this module could see
/// past `private` or `internal` regardless.
///
/// **This was a pure move.** Nothing here changed when it arrived, including
/// `send(_:)`'s untracked `Task` - which is a known and deliberately
/// out-of-scope wart, not something this split fixed or introduced.
public extension ChatSessionModel {
    /// Forwarded from the backend so a view can degrade without meeting one.
    /// Here rather than in `ChatSessionModel.swift`, for that file's length.
    var capabilities: Capabilities {
        engine.capabilities
    }

    /// The failed message, mentions and all, but only while its own
    /// conversation is open.
    var failedDraft: ComposedMessage? {
        guard let failed, failed.conversationID == selected else { return nil }
        return failed.draft
    }

    /// Called by the host once it has put the text back, so it is not offered
    /// again on the next redraw.
    func clearFailedDraft() {
        failed = nil
    }

    /// Sends, and shows the message immediately.
    ///
    /// The optimistic row carries a `local/`-prefixed id because it has no
    /// server id yet and inventing one that later collides with a real message
    /// id would be worse than an obviously-local one. `ChatStore` replaces it
    /// when the echo arrives, matched on `localID` - see `Message.localID`,
    /// which has documented exactly this since the seam was written.
    ///
    /// A backend that cannot send is not asked. The composer is already hidden
    /// in that case, but a model that wrote an optimistic row anyway would show
    /// a message that never leaves.
    ///
    /// With files staged, the text goes with the first of them instead
    /// (`sendStaged(_:in:)`). Mentions ride on the optimistic row too, so the
    /// bubble highlights at once, and on a refused draft, so a resend still
    /// mentions (mention composer spec §2).
    func send(_ message: ComposedMessage) {
        guard let selected, capabilities.canSendMessages else { return }
        if stagedAttachments.contains(where: { !$0.isUploading }) {
            sendStaged(message, in: StagingKey(conversation: selected, thread: nil))
            return
        }
        let text = message.text
        // Only a staged file makes an empty send mean something. A composer
        // one frame behind its staged files must not post an empty message.
        guard !text.isEmpty else { return }
        let localID = UUID().uuidString
        // Invented here, and therefore retracted from here. The `local/`
        // prefix is this file's convention and stays this file's business:
        // `ChatStore` deletes a row by id and has never heard of it.
        let optimisticID = Message.ID("local/\(localID)")
        var undo: [StoreWrite] = []
        if let me {
            try? store.apply([.upsertMessage(Message(
                id: optimisticID,
                conversationID: selected,
                threadID: MessageThread.ID(""),
                sender: me,
                text: text,
                createdAt: Date(),
                localID: localID,
                mentions: message.mentions
            ))])
            // Only what was actually written. With no `me` there is no
            // optimistic row and nothing to take back.
            undo = [.removeMessage(id: optimisticID)]
        }
        Task { @MainActor [weak self, engine] in
            let accepted = await engine.submit(
                .sendMessage(
                    conversationID: selected, threadID: nil, text: text, localID: localID,
                    mentions: message.mentions
                ),
                // By id, not by `localID`. The server echoes `localID` back on
                // the delivered message, so a `localID` retraction would
                // delete the real one whenever the echo beat the failure -
                // which is exactly the `/api/` timeout this whole retraction
                // was written for.
                undoing: undo
            )
            guard let self, !accepted else { return }
            failed = (conversationID: selected, draft: message)
        }
    }

    /// Sends, but only into `conversation`, and only while it is the one open.
    /// The composer's confirmation awaits a membership check, and the person
    /// may open another conversation meanwhile: the message then goes back to
    /// its own conversation's draft rather than into the one now open (mention
    /// non-members review finding 2).
    func send(_ message: ComposedMessage, in conversation: Conversation.ID) {
        guard conversation == selected else {
            keepDraft(message, in: conversation)
            return
        }
        send(message)
    }

    /// Hands `message` back to `conversation`'s composer, the way a refused
    /// send does: for a composer that went away holding an unsent message.
    func keepDraft(_ message: ComposedMessage, in conversation: Conversation.ID) {
        guard !message.text.isEmpty else { return }
        failed = (conversationID: conversation, draft: message)
    }
}
