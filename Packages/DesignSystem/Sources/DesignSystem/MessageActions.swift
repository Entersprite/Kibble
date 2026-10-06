import ChatKit

/// Saving an edit and deleting a message, for the person's own messages
/// (edit spec §5). **Optional on `ChatSceneActions`, and `nil` is the point**:
/// a backend that can do neither gets no Edit… or Delete… anywhere.
public struct MessageActions {
    public var save: (Message.ID, ComposedMessage) -> Void
    public var delete: (Message.ID) -> Void

    public init(
        save: @escaping (Message.ID, ComposedMessage) -> Void,
        delete: @escaping (Message.ID) -> Void
    ) {
        self.save = save
        self.delete = delete
    }
}

/// What a bubble's menus may offer: `ChatWindow` builds it, so starting an
/// edit or asking to delete stays a window decision. A `nil` handler means
/// the backend cannot, and draws no item.
struct OwnMessageHandlers {
    var me: Member.ID?
    var edit: ((Message) -> Void)?
    var delete: ((Message) -> Void)?

    /// `nil` when the message offers neither (`OwnMessageRule`).
    func items(for message: Message) -> OwnMessageMenuItems? {
        let edit = edit.flatMap { edit in
            OwnMessageRule.canEdit(message, me: me) ? { edit(message) } : nil
        }
        let delete = delete.flatMap { delete in
            OwnMessageRule.canDelete(message, me: me) ? { delete(message) } : nil
        }
        guard edit != nil || delete != nil else { return nil }
        return OwnMessageMenuItems(edit: edit, delete: delete)
    }
}

/// One message's Edit… and Delete…, each `nil` when not offered.
struct OwnMessageMenuItems {
    let edit: (() -> Void)?
    let delete: (() -> Void)?
}
