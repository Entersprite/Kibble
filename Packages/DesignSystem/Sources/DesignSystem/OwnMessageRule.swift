import ChatKit

/// Which messages offer Edit… and Delete… (edit spec §5). Both menus and the
/// Up arrow ask this, so they cannot disagree.
///
/// Mine, not deleted, and not still sending (`local/`, the optimistic send's
/// prefix, has no server id to address). Edit also needs text and no
/// attachment: whether an edit keeps an attachment is unmeasured, and a
/// message whose picture an edit dropped could not be put back.
enum OwnMessageRule {
    /// Not deleted and not still sending: a message a menu item can act on,
    /// anyone's. The thread items ask this too (threads spec §5).
    static func isAddressable(_ message: Message) -> Bool {
        !message.isDeleted && !message.id.rawValue.hasPrefix("local/")
    }

    /// A `nil` me matches no sender, so nothing is mine before the account
    /// is identified.
    static func canDelete(_ message: Message, me: Member.ID?) -> Bool {
        message.sender == me && isAddressable(message)
    }

    static func canEdit(_ message: Message, me: Member.ID?) -> Bool {
        canDelete(message, me: me) && !message.text.isEmpty && message.attachments.isEmpty
    }

    /// What Up arrow edits: the last editable message, in transcript order.
    static func newestEditable(in messages: [Message], me: Member.ID?) -> Message? {
        messages.last { canEdit($0, me: me) }
    }
}
