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
    /// The failed text, but only while its own conversation is open.
    var failedDraft: String? {
        guard let failed, failed.conversationID == selected else { return nil }
        return failed.text
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
    func send(_ text: String) {
        guard let selected, capabilities.canSendMessages else { return }
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
                localID: localID
            ))])
            // Only what was actually written. With no `me` there is no
            // optimistic row and nothing to take back.
            undo = [.removeMessage(id: optimisticID)]
        }
        Task { @MainActor [weak self, engine] in
            let accepted = await engine.submit(
                .sendMessage(
                    conversationID: selected, threadID: nil, text: text, localID: localID
                ),
                // By id, not by `localID`. The server echoes `localID` back on
                // the delivered message, so a `localID` retraction would
                // delete the real one whenever the echo beat the failure -
                // which is exactly the `/api/` timeout this whole retraction
                // was written for.
                undoing: undo
            )
            guard let self, !accepted else { return }
            failed = (conversationID: selected, text: text)
        }
    }
}
