import ChatKit
import Foundation

// MARK: - Sending

public extension SyncEngine {
    /// A definite refusal retracts only the exact optimistic rows supplied by
    /// the caller. A canonical echo with the same localID is never retracted.
    ///
    /// An uncertain message send keeps its pending row and consumes the draft,
    /// preventing a blind duplicate. Other uncertain commands still return false
    /// so they cannot advance success-dependent state such as read watermarks.
    /// Tracked message sends persist their original identity before dispatch and
    /// reconcile through read-only status checks, including after restart.
    ///
    /// True means the submission was acknowledged or its uncertain message is
    /// retained for reconciliation. It is not a claim that an unknown send arrived.
    @discardableResult
    func submit(_ command: ChatCommand, undoing writes: [StoreWrite] = []) async -> Bool {
        let generation = managementGeneration
        guard canDispatchTrackedMessage(command, undoing: writes) else { return false }
        if suppressed(command) {
            // A refused mark still means the messages it covers are read
            // here - receipts off, no account yet, or ghost mode - so their
            // banners go, locally. The automatic trigger marks what was on
            // screen; an explicit mark (a banner's button or the sidebar's)
            // marks what the user asked to. A published mark announces nothing
            // here: the server's read state does, through the reducer.
            //
            // **One microsecond past `upTo`, never `upTo` itself.** A mark's
            // `upTo` is the newest seen message's own `createdAt`. While a
            // `.read` covered only `createdAt < upTo`, announcing it unchanged
            // left the newest banner, usually the only one, up for good. The
            // withdraw now covers equality too (`findings.md` §42.2), and the
            // step is kept: it matches the wire's, which the backend adds
            // (`readPositionOffsetMicroseconds`) on a path this never reaches.
            if case let .markRead(conversation, upTo) = command {
                announcer.yield(.read(conversation, upTo: upTo.addingTimeInterval(0.000_001)))
            }
            return false
        }
        if case let .conversationAction(id, action) = command {
            return await submitConversationAction(action, in: id) == nil
        }
        do {
            try command.validateMessageContent(capabilities: backend.capabilities)
            try await backend.send(command)
            try Task.checkCancellation()
            guard generation == managementGeneration else { return false }
            recordAcceptedDelivery(command, undoing: writes)
            return true
        } catch {
            // Same reasoning as `requestMoreMessages` and `perform` just below:
            // cancelling this task does not oblige whatever is underneath it to
            // throw `CancellationError`, and a write from a session that no
            // longer owns the store is the exact trap `ChatSessionModel.stop()`
            // cancelling `markTasks` exists to close.
            guard !Task.isCancelled, generation == managementGeneration else { return false }
            if error is UncertainOperation {
                let status = deliveryUpdates(in: writes, status: .unconfirmed)
                record(
                    ChatError.unknown("Delivery is unconfirmed. Check its status before sending again."),
                    undoing: status
                )
                // Consume the original send without restoring a resendable
                // draft or retracting its pending row. Other commands still
                // cannot advance success-dependent state such as read receipts.
                if case .sendMessage = command {
                    return true
                }
                return false
            }
            record(error, undoing: writes)
            return false
        }
    }

    /// The one place the read-receipt gate is enforced, and the dormant
    /// ghost-mode switch with it.
    ///
    /// A `.markRead`, a `.markThreadRead` and the clear sent before one
    /// (`.setThreadUnreadMark` with `at: nil`) are refused when their
    /// conversation's resolved rule has `readReceipts` off
    /// (`receiptsAllowed(in:)`); a manual Mark as Unread (`at:` set) never is.
    /// `ghostMode` is checked too, though no host sets it any more - see its
    /// doc comment.
    ///
    /// **`ghostSuppresses` is exhaustive with no `default`, on purpose.** A new
    /// `ChatCommand` case stops it compiling until someone decides whether it
    /// says something about this user that ghost mode should withhold. That
    /// compile error is the guarantee; a two-case `if` would let the next one
    /// leak by default. Same idiom as `SyncReducer.reduce(_:)` and
    /// `ConnectionIssueMapping`.
    private func suppressed(_ command: ChatCommand) -> Bool {
        if ghostMode, ghostSuppresses(command) {
            return true
        }
        switch command {
        case let .setTyping(id, _, true):
            guard let conversation = (try? store.conversations())?.first(where: { $0.id == id }) else {
                return true
            }
            return !typingPrivacy.allows(conversation)
        case let .markRead(conversationID, _), let .markThreadRead(conversationID, _, _),
             let .setThreadUnreadMark(conversationID, _, nil):
            return !receiptsAllowed(in: conversationID)
        default:
            return false
        }
    }

    /// Exhaustive on purpose - a new command must be decided here, not
    /// silently let through.
    private func ghostSuppresses(_ command: ChatCommand) -> Bool {
        switch command {
        case .markRead, .markThreadRead, .setTyping, .reportActivity:
            // Activity is presence, which is exactly what ghosting withholds.
            // A thread's read position says what you have read, as a
            // conversation's does; whether others see it is `[Verify]`.
            true
        case .sendMessage, .editMessage, .deleteMessage, .setReaction, .setThreadUnreadMark,
             .setNotificationLevel, .watchPresence, .loadMembers, .setStatus, .setAvailability,
             .conversationAction, .watchConversationActivity, .unknown:
            // `.watchPresence` and `.loadMembers` ask about other people and
            // say nothing about this one. Setting your own status is an act,
            // and an unread mark is yours alone.
            false
        }
    }

    private func receiptsAllowed(in id: Conversation.ID) -> Bool {
        switch readReceipts.policy {
        case .publish:
            return true
        case .withhold:
            return false
        case let .resolve(settings):
            // A conversation the store has not listed yet resolves through
            // Other - the same fallback the notification path uses.
            let conversation = (try? store.conversations())?.first { $0.id == id }
                ?? Conversation(id: id, kind: .unknown(""))
            return settings.resolve(for: conversation).readReceipts
        }
    }

    /// Fetches a page of history, recording a failure rather than throwing.
    ///
    /// The same contract as `submit(_:)` and for the same reason: the caller
    /// is a view opening a conversation, and a view has nowhere to put a
    /// thrown error. `loadMoreMessages` still throws for callers that can
    /// handle it - the reducer's `.reloadMessages` effect is one - but the
    /// UI path had been swallowing that throw with `try?`, so a dead channel
    /// rendered as an empty transcript with no explanation.
    @discardableResult
    func requestMoreMessages(
        in conversation: Conversation.ID, before: Message.ID? = nil,
        verifyCachedRoots: Bool = false
    ) async -> [Message]? {
        do {
            return try await loadMoreMessages(
                in: conversation, before: before, verifyCachedRoots: verifyCachedRoots
            )
        } catch {
            // A deliberate stop is not a failure - `ChatSessionModel.select(_:)`
            // and `.stop()` both cancel `historyTask` to drop interest in an
            // in-flight fetch. Matching on `CancellationError` here used to be
            // how that was told apart from a real failure, but cancelling a
            // `Task` does not oblige whatever is underneath it to throw
            // Swift's own error: `URLSessionTransport` throws
            // `URLError(.cancelled)`, which `LocalBridgeBackend` then turns
            // into an ordinary-looking `ChatError.transport(...)` -
            // indistinguishable, by type, from a real one. The error's shape
            // is an implementation detail of whatever transport produced it,
            // and a future one could throw something else again.
            //
            // `Task.isCancelled` asks the question that actually matters:
            // did *this* task ask to stop. Recording despite that would
            // itself be a write from a session that no longer owns this
            // store - the same trap `loadMoreMessages`'s own cancellation
            // check exists to close, one layer up. And because this reads
            // our own task rather than the error, a failure that merely
            // *looks* like a cancellation - thrown while nobody here
            // cancelled anything - still falls through to `record` below,
            // exactly as it should.
            guard !Task.isCancelled else { return nil }
            record(error)
            return nil
        }
    }
}
