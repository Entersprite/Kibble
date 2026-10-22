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
/// edit, asking to delete, opening a thread and marking a reply unread stay
/// window decisions. The name predates the thread items, which are offered on
/// anyone's message (threads plan, ruling 1). A `nil` handler draws no item.
struct OwnMessageHandlers {
    var me: Member.ID?
    var edit: ((Message) -> Void)?
    var delete: ((Message) -> Void)?
    /// "Reply in Thread", on a top-level message with no replies yet.
    var replyInThread: ((Message) -> Void)?
    /// "Mark as Unread", on a reply in the thread panel.
    var markUnread: ((Message) -> Void)?
    /// Whether a message's thread has replies already: the mark opens those.
    var hasReplies: (Message) -> Bool = { _ in false }
    var quote: ((Message) -> Void)?
    var forward: ((Message) -> Void)?
    /// Saved rows not yet confirmed: they may since have been edited or
    /// deleted elsewhere, so neither is offered on them until they are.
    var unconfirmed: Set<Message.ID> = []

    /// `nil` when the message offers nothing.
    func items(for message: Message) -> OwnMessageMenuItems? {
        let confirmed = !unconfirmed.contains(message.id)
        let edit = edit.flatMap { edit in
            confirmed && OwnMessageRule.canEdit(message, me: me) ? { edit(message) } : nil
        }
        let delete = delete.flatMap { delete in
            confirmed && OwnMessageRule.canDelete(message, me: me) ? { delete(message) } : nil
        }
        let addressable = OwnMessageRule.isAddressable(message)
        let reply = replyInThread.flatMap { reply in
            addressable && !message.isReply && !hasReplies(message) ? { reply(message) } : nil
        }
        let unread = markUnread.flatMap { mark in
            addressable && message.isReply ? { mark(message) } : nil
        }
        let quote = quote.flatMap { action in
            addressable && message.callStatus == nil ? { action(message) } : nil
        }
        let forward = forward.flatMap { action in
            addressable && !message.isDeleted && message.callStatus == nil ? { action(message) } : nil
        }
        guard edit != nil || delete != nil || reply != nil || unread != nil || quote != nil || forward != nil
        else { return nil }
        return OwnMessageMenuItems(
            edit: edit,
            delete: delete,
            replyInThread: reply,
            markUnread: unread,
            quote: quote, forward: forward
        )
    }
}

/// One message's menu items, each `nil` when not offered.
struct OwnMessageMenuItems {
    let edit: (() -> Void)?
    let delete: (() -> Void)?
    var replyInThread: (() -> Void)?
    var markUnread: (() -> Void)?
    var quote: (() -> Void)?
    var forward: (() -> Void)?
}
