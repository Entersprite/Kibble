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
    /// already superseded, lose the first toggle silently.
    ///
    /// The toggled set is written straight to the store, folded with
    /// `[Reaction].applying` - the same fold the fixture uses - and the command
    /// carries the message's conversation and thread, which a backend needs to
    /// address it (`ChatCommand.setReaction`). The submission is chained after
    /// whatever this session last sent and tracked
    /// (`ChatSessionModel.reactionTasks`/`reactionChainTail`), so two quick
    /// toggles reach the wire in the order they were clicked and `stop()` can
    /// cancel whichever is still running - the same reasoning as `markTasks`.
    /// A refusal puts the previous set back and shows the error, in one
    /// transaction (`SyncEngine.submit`).
    ///
    /// **Known gap, accepted rather than fixed:** a refusal restores the
    /// snapshot taken at its own click, so a late refusal can briefly erase a
    /// later toggle's optimistic write until the next push or history load
    /// corrects it (reactions spec §3).
    ///
    /// Does nothing for a message that has no server id yet (`local/`, the
    /// optimistic send's prefix), for a toggle that would change nothing, and
    /// on a backend that cannot react.
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
            undoing: [.setReactions(messageID: messageID, reactions: previous)]
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
    private func submitReaction(_ command: ChatCommand, undoing writes: [StoreWrite]) {
        let id = UUID()
        let previousTail = reactionChainTail
        let task = Task { @MainActor [weak self, engine] in
            _ = await previousTail?.value
            guard !Task.isCancelled else { return }
            await engine.submit(command, undoing: writes)
            self?.reactionTasks.removeValue(forKey: id)
        }
        reactionTasks[id] = task
        reactionChainTail = task
    }
}
