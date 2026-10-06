import ChatKit
import Foundation

// MARK: - Editing and deleting the person's own messages

/// Its own file for swiftlint's `file_length`, like `+Reactions.swift`, whose
/// write-first shape it follows (edit spec §4).
public extension ChatSessionModel {
    /// Writes the new text and mentions at once, then submits. Reads the row
    /// from the store, never `messages`, for `react`'s reason.
    ///
    /// **On refusal the old row comes back only if the stored row is still
    /// this edit.** A `MESSAGE_UPDATED` that landed meanwhile is the server's
    /// version, and an undo must not overwrite it. Compared on text and
    /// mentions, not on `editedAt`, because a date read back from the store is
    /// only as precise as the store (CLAUDE.md).
    ///
    /// Does nothing on a backend that cannot edit, for a message still
    /// sending (`local/`), for one not in the store or deleted, for empty
    /// text, and for an edit that changes nothing.
    func edit(_ id: Message.ID, to message: ComposedMessage) {
        guard capabilities.canEditMessages,
              !id.rawValue.hasPrefix("local/"),
              let original = try? store.message(id),
              !original.isDeleted,
              !message.text.isEmpty,
              message.text != original.text || message.mentions != original.mentions
        else { return }
        var edited = original
        edited.text = message.text
        edited.mentions = message.mentions
        edited.editedAt = Date()
        try? store.apply([.upsertMessageKeepingReactions(edited)])
        submitEdit(
            .editMessage(
                id: id, text: message.text, conversationID: original.conversationID,
                threadID: original.threadID, mentions: message.mentions
            ),
            restoring: original
        ) { current in
            !current.isDeleted && current.text == edited.text && current.mentions == edited.mentions
        }
    }

    /// Tombstones the message at once, then submits; on refusal puts the old
    /// row back - reactions included - if the stored row is still a tombstone.
    func delete(_ id: Message.ID) {
        guard capabilities.canDeleteMessages,
              !id.rawValue.hasPrefix("local/"),
              let original = try? store.message(id),
              !original.isDeleted
        else { return }
        try? store.apply([.markMessageDeleted(id: id, in: original.conversationID)])
        submitEdit(
            .deleteMessage(id: id, conversationID: original.conversationID, threadID: original.threadID),
            restoring: original
        ) { current in current.isDeleted }
    }

    /// Submits `command`; on refusal, and only while `stillOurs` holds for
    /// the stored row, writes `original` back. Nothing is written once the
    /// task is cancelled (`stop()`), the guard `markTasks` observes.
    private func submitEdit(
        _ command: ChatCommand,
        restoring original: Message,
        stillOurs: @escaping @MainActor (Message) -> Bool
    ) {
        let key = UUID()
        let task = Task { @MainActor [weak self, engine, store] in
            let accepted = await engine.submit(command, undoing: [])
            if !accepted, !Task.isCancelled, let current = try? store.message(original.id),
               stillOurs(current) {
                try? store.apply([.upsertMessage(original)])
            }
            self?.editTasks.removeValue(forKey: key)
        }
        editTasks[key] = task
    }
}
