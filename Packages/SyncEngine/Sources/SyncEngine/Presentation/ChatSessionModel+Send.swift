import ChatKit
import ChatPersistence
import Foundation

// MARK: - Sending, and the draft a refused send hands back

/// Split out of `ChatSessionModel.swift` to keep that file under swiftlint's
/// `file_length` ceiling, which it had reached exactly - the same reason
/// `ChatSessionModel+AutoMarkRead.swift` next door exists, and the precedent
/// `LiveChannelTests.swift` records for splitting a file rather than trimming
/// a doc comment to fit.
///
/// `failedDrafts` and `store` are declared in `ChatSessionModel.swift` without
/// `private` (plain `internal`) specifically so this extension - in a
/// different source file, where Swift's same-file `private` visibility does
/// not reach - can read and write them, exactly as `published`, `markTasks`
/// and `engine` are already spelled for `+AutoMarkRead.swift`. The public
/// surface is unchanged either way: nothing outside this module could see
/// past `private` or `internal` regardless.
///
public extension ChatSessionModel {
    struct FailedDraftOffer {
        public let conversationID: Conversation.ID
        public let id = UUID()
        public let draft: ComposedMessage
    }

    /// Forwarded from the backend so a view can degrade without meeting one.
    /// Here rather than in `ChatSessionModel.swift`, for that file's length.
    var capabilities: Capabilities {
        engine.capabilities
    }

    /// The refused draft visible to the current composer.
    var failedDraft: ComposedMessage? {
        failedDraftOffer?.draft
    }

    /// The original conversation and value the composer is being offered.
    var failedDraftOffer: FailedDraftOffer? {
        guard let selected, !failedDrafts.isEmpty else { return nil }
        if let draft = failedDrafts[selected]?.first {
            return draft
        }
        // A meeting series uses one composer even when the most recent
        // occurrence changes while a send to the previous one is in flight.
        guard let series = meetingSeries else { return nil }
        for occurrence in series.occurrences.reversed() {
            if let draft = failedDrafts[occurrence.id]?.first {
                return draft
            }
        }
        return nil
    }

    /// Called by the host once it has put the text back, so it is not offered
    /// again on the next redraw.
    func clearFailedDraft() {
        guard let offer = failedDraftOffer else { return }
        clearFailedDraft(in: offer.conversationID, matching: offer.id)
    }

    /// Consume exactly the offer the composer acknowledged.
    func clearFailedDraft(in conversation: Conversation.ID, matching id: UUID) {
        guard failedDrafts[conversation]?.first?.id == id else { return }
        failedDrafts[conversation]?.removeFirst()
        if failedDrafts[conversation]?.isEmpty == true {
            failedDrafts[conversation] = nil
        }
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
    /// (`sendStaged`). Mentions ride on the optimistic row too, so the
    /// bubble highlights at once, and on a refused draft, so a resend still
    /// mentions (mention composer spec §2).
    func send(_ message: ComposedMessage) {
        send(message, consuming: nil, completed: nil)
    }

    internal func send(
        _ message: ComposedMessage, using reserved: [StagedAttachment]? = nil,
        consuming draft: SyncedDraft?, completed: (@MainActor (Bool) -> Void)?
    ) {
        guard let selected, capabilities.canSendMessages else {
            completed?(false)
            return
        }
        let key = StagingKey(conversation: selected, thread: nil)
        let batch = reserved ?? reserveStagedFiles(in: key)
        if !batch.isEmpty {
            followLatestMeetingForSend()
            sendStaged(batch, caption: message, in: key, consuming: draft, completed: completed)
            return
        }
        let text = message.text
        // Only a staged file makes an empty send mean something. A composer
        // one frame behind its staged files must not post an empty message.
        guard !text.isEmpty else {
            completed?(false)
            return
        }
        followLatestMeetingForSend()
        let localID = ClientOperationID.make()
        // Invented here, and therefore retracted from here. The `local/`
        // prefix is this file's convention and stays this file's business:
        // `ChatStore` deletes a row by id and has never heard of it.
        let optimisticID = Message.ID("local/\(localID)")
        var undo: [StoreWrite] = []
        if let me {
            guard beginOptimistic(Message(
                id: optimisticID,
                conversationID: selected,
                threadID: MessageThread.ID(""),
                sender: me,
                text: text,
                createdAt: Date(),
                localID: localID,
                mentions: message.mentions, content: message.content
            )) else {
                keepDraft(message, in: selected)
                completed?(false)
                return
            }
            // Only what was actually written. With no `me` there is no
            // optimistic row and nothing to take back. Retract by row ID,
            // since the delivered echo can already carry the same local ID.
            undo = [.removeMessage(id: optimisticID)]
        }
        let command = ChatCommand.sendMessage(
            conversationID: selected, threadID: nil, text: text, localID: localID,
            mentions: message.mentions, content: message.content
        )
        submitText(command, consuming: draft, undoing: undo, completed: completed) { model in
            model.keepDraft(message, in: selected)
        }
    }

    internal func submitText(
        _ command: ChatCommand, consuming draft: SyncedDraft?, undoing undo: [StoreWrite],
        completed: (@MainActor (Bool) -> Void)?, onRefusal: @escaping @MainActor (ChatSessionModel) -> Void
    ) {
        didBeginSending?()
        let taskID = UUID()
        sendTasks[taskID] = Task { @MainActor [weak self, engine] in
            defer { self?.sendTasks.removeValue(forKey: taskID) }
            guard !Task.isCancelled else { return }
            let result = await engine.submit(command, consuming: draft, undoing: undo)
            guard let self, !Task.isCancelled else { return }
            completed?(result.draftConsumed)
            if !result.retained {
                onRefusal(self)
            }
        }
    }

    /// Sends, but only into `conversation`, and only while it is the one open.
    /// The composer's confirmation awaits a membership check, and the person
    /// may open another conversation meanwhile: the message then goes back to
    /// its own conversation's draft rather than into the one now open (mention
    /// non-members review finding 2).
    func send(_ message: ComposedMessage, in conversation: Conversation.ID) {
        send(message, in: conversation, consuming: nil, completed: nil)
    }

    func send(
        _ message: ComposedMessage, in conversation: Conversation.ID,
        consuming draft: SyncedDraft?, completed: (@MainActor (Bool) -> Void)?
    ) {
        guard conversation == selected else {
            keepDraft(message, in: conversation)
            completed?(false)
            return
        }
        send(message, consuming: draft, completed: completed)
    }

    /// Hands `message` back to `conversation`'s composer, the way a refused
    /// send does: for a composer that went away holding an unsent message.
    func keepDraft(_ message: ComposedMessage, in conversation: Conversation.ID) {
        guard !message.text.isEmpty else { return }
        let offer = FailedDraftOffer(conversationID: conversation, draft: message)
        failedDrafts[conversation, default: []].append(offer)
    }

    /// `send(_:in:)` for the thread panel's composer: a reply, posted only
    /// while `thread` is the one open in `conversation`, and otherwise handed
    /// back to that thread's draft.
    func sendReply(_ message: ComposedMessage, in conversation: Conversation.ID, thread: MessageThread.ID) {
        sendReply(message, in: conversation, thread: thread, consuming: nil, completed: nil)
    }

    func sendReply(
        _ message: ComposedMessage, in conversation: Conversation.ID, thread: MessageThread.ID,
        consuming draft: SyncedDraft?, completed: (@MainActor (Bool) -> Void)?
    ) {
        guard conversation == selected, thread == threads.openThread else {
            keepReplyDraft(message, in: conversation, thread: thread)
            completed?(false)
            return
        }
        sendReply(message, consuming: draft, completed: completed)
    }

    /// Hands `message` back to the thread's composer, as a refused reply is.
    func keepReplyDraft(
        _ message: ComposedMessage,
        in conversation: Conversation.ID,
        thread: MessageThread.ID
    ) {
        restoreReply(message, in: StagingKey(conversation: conversation, thread: thread))
    }
}
