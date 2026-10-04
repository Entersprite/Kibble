import ChatKit
import Foundation

// MARK: - Reactions

/// Its own file for swiftlint's `file_length`, like `+Send.swift`.
public extension ChatSessionModel {
    /// Adds or removes the person's own reaction, and shows it at once.
    ///
    /// Reads the message from the store (`ChatStore.message(_:)`) rather than
    /// from `messages`: a GRDB `ValueObservation` refreshes `messages` only
    /// after its tracked query re-runs, asynchronously, so a second toggle
    /// issued before that refresh would fold against a row `store.apply` has
    /// already superseded, losing the first toggle silently.
    ///
    /// The toggled set is written straight to the store, folded with
    /// `[Reaction].applying` - the same fold the fixture uses - and the command
    /// carries the message's conversation and thread, which a backend needs to
    /// address it (`ChatCommand.setReaction`). The submission is chained after
    /// whatever this session last sent and tracked
    /// (`ChatSessionModel.reactionTasks`/`reactionChainTail`), so two quick
    /// toggles reach the wire in the order they were clicked and `stop()` can
    /// cancel whichever is still running - the same reasoning as `markTasks`.
    ///
    /// **A refusal undoes by folding the inverse against the current row, not
    /// by restoring a snapshot taken at click time.** `submitReaction` passes
    /// `SyncEngine.submit` an empty `undoing:`, and on a `false` return - with
    /// the task not itself cancelled - re-reads the message from the store and
    /// writes `current.reactions.applying(choice, add: !add)`: the opposite of
    /// this toggle, applied to whatever the row holds *now*. A snapshot goes
    /// stale the moment a second toggle lands before the first's refusal
    /// comes back: with the session expired, adding 🛞 then 👍 used to have
    /// A's refusal restore the snapshot from before A's own click (wiping
    /// 👍), then B's refusal restore the snapshot from before B's click
    /// (putting 🛞 back) - a reaction the server never accepted, left behind
    /// because each restore undid to a fixed point instead of undoing its own
    /// effect. Folding the inverse against the current row undoes exactly one
    /// toggle regardless of what else has landed since, the same reasoning
    /// `[Reaction].applying`'s own idempotence exists for. The error is still
    /// recorded and shown on refusal either way - `SyncEngine.submit` writes
    /// `.setLastError` whether or not `undoing` is empty.
    ///
    /// **Remaining limitation:** when an add and a remove of the *same* emoji
    /// are both refused, their inverse folds are independent - neither knows
    /// about the other's click - and can still leave a phantom entry (or drop
    /// a real one) until the next push or history load corrects it.
    ///
    /// Does nothing: on a backend that cannot react (`capabilities.canReact`);
    /// for a message that has no server id yet (`local/`, the optimistic
    /// send's prefix); for a message not in the store, or a store read error
    /// (`try? store.message`); and for a toggle that would change nothing.
    func react(to messageID: Message.ID, with choice: ReactionChoice, add: Bool) {
        guard capabilities.canReact,
              !messageID.rawValue.hasPrefix("local/"),
              let message = try? store.message(messageID)
        else { return }
        let previous = message.reactions
        let next = previous.applying(choice, add: add)
        guard next != previous else { return }
        try? store.apply([.setReactions(messageID: messageID, reactions: next)])
        submitReaction(
            .setReaction(
                messageID: messageID, emoji: choice.emoji, add: add,
                conversationID: message.conversationID, threadID: message.threadID,
                customEmoji: choice.customEmoji
            ),
            messageID: messageID, choice: choice, add: add
        )
    }

    /// Chains `command` after whatever this session last submitted through
    /// here, and tracks the `Task` so `stop()` can cancel it.
    ///
    /// Keyed by a per-call id rather than kept as a plain array, so a
    /// finished task removes exactly its own entry without disturbing one
    /// still running - `reactionTasks` does not grow without bound because of
    /// that removal, and `reactionChainTail` (not itself in the dictionary) is
    /// the one handle `react` chains the next submission after.
    ///
    /// On refusal, folds the inverse of `choice`/`add` against whatever the
    /// store holds *at that moment* - see `react(to:with:add:)`'s doc comment
    /// for why that, rather than the snapshot taken at click time, is what
    /// undoes correctly when toggles chain. Nothing is folded when the task
    /// was itself cancelled first (`stop()`): a session that no longer owns
    /// the store must not write to it, the same guard `markTasks` observes.
    private func submitReaction(
        _ command: ChatCommand,
        messageID: Message.ID,
        choice: ReactionChoice,
        add: Bool
    ) {
        let id = UUID()
        let previousTail = reactionChainTail
        let task = Task { @MainActor [weak self, engine, store] in
            _ = await previousTail?.value
            guard !Task.isCancelled else { return }
            let accepted = await engine.submit(command, undoing: [])
            if !accepted, !Task.isCancelled, let current = try? store.message(messageID) {
                try? store.apply([.setReactions(
                    messageID: messageID, reactions: current.reactions.applying(choice, add: !add)
                )])
            }
            self?.reactionTasks.removeValue(forKey: id)
        }
        reactionTasks[id] = task
        reactionChainTail = task
    }
}
