import ChatKit
import Foundation

/// An edit to begin, from a menu: `id` makes asking twice for the same
/// message a new request.
public struct ComposerEditRequest: Equatable {
    public let id: UUID
    public let messageID: Message.ID
    public let message: ComposedMessage

    public init(messageID: Message.ID, message: ComposedMessage, id: UUID = UUID()) {
        self.id = id
        self.messageID = messageID
        self.message = message
    }
}

/// What the composer needs to edit (edit spec §5). `nil` on `Composer` means
/// no edit mode at all.
public struct ComposerEditing {
    public var request: ComposerEditRequest?
    /// What Up arrow edits (`OwnMessageRule.newestEditable`).
    public var newest: Message?
    public var save: (Message.ID, ComposedMessage) -> Void
    /// Told when an edit begins and ends, so the window can refuse file drops
    /// meanwhile and forget the request.
    public var began: (Message.ID) -> Void
    public var ended: () -> Void

    public init(
        request: ComposerEditRequest?,
        newest: Message?,
        save: @escaping (Message.ID, ComposedMessage) -> Void,
        began: @escaping (Message.ID) -> Void,
        ended: @escaping () -> Void
    ) {
        self.request = request
        self.newest = newest
        self.save = save
        self.began = began
        self.ended = ended
    }
}

/// The composer's keys while an edit is possible, as decisions a test can
/// reach (`ComposerDraft`'s reasoning).
enum ComposerEditKeys {
    enum Submit: Equatable {
        case send, save, nothing
    }

    /// Return: save while editing - never send, so staged files stay staged -
    /// and nothing for an empty edit (removing a message is Delete's job).
    static func submitAction(draft: ComposerDraft, canSend: Bool) -> Submit {
        if draft.editing != nil {
            return draft.composed().text.isEmpty ? .nothing : .save
        }
        return canSend ? .send : .nothing
    }

    /// Up edits the newest editable message only from an empty, idle
    /// composer; otherwise Up moves the caret or the highlight as before.
    static func upEdits(draft: ComposerDraft, stagedCount: Int, listOpen: Bool, newest: Message?) -> Bool {
        draft.editing == nil && draft.text.isEmpty && stagedCount == 0 && !listOpen && newest != nil
    }

    /// Esc closes an open `@` list first; only then does it cancel an edit.
    static func escCancels(draft: ComposerDraft, listOpen: Bool) -> Bool {
        draft.editing != nil && !listOpen
    }
}
