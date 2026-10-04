import ChatKit
import Foundation

// MARK: - Reactions

/// Its own file for swiftlint's `file_length`, like `+Send.swift`.
public extension ChatSessionModel {
    /// Adds or removes the person's own reaction, and shows it at once.
    ///
    /// The toggled set is written straight to the store, folded with
    /// `[Reaction].applying` - the same fold the fixture uses - and the command
    /// carries the message's conversation and thread, which a backend needs to
    /// address it (`ChatCommand.setReaction`). A refusal puts the previous set
    /// back and shows the error, in one transaction (`SyncEngine.submit`).
    ///
    /// The fold reads `messages`, which the store's observation refreshes after
    /// each write, so a second toggle folds against the first one's result.
    /// A push that lands between a write and a refusal is overwritten by the
    /// undo; the next push or history load corrects it (reactions spec §3).
    ///
    /// Does nothing for a message that has no server id yet (`local/`, the
    /// optimistic send's prefix), for a toggle that would change nothing, and
    /// on a backend that cannot react.
    func react(to messageID: Message.ID, with choice: ReactionChoice, add: Bool) {
        guard capabilities.canReact,
              !messageID.rawValue.hasPrefix("local/"),
              let message = messages.first(where: { $0.id == messageID })
        else { return }
        let previous = message.reactions
        let next = previous.applying(choice, add: add)
        guard next != previous else { return }
        try? store.apply([.setReactions(messageID: messageID, reactions: next)])
        Task { @MainActor [engine] in
            await engine.submit(
                .setReaction(
                    messageID: messageID, emoji: choice.emoji, add: add,
                    conversationID: message.conversationID, threadID: message.threadID,
                    customEmoji: choice.customEmoji
                ),
                undoing: [.setReactions(messageID: messageID, reactions: previous)]
            )
        }
    }
}
