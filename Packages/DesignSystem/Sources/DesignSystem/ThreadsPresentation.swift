import ChatKit

/// What the Threads row, the list and the sidebar say. Pure, so every state is
/// a test.
public enum ThreadsPresentation {
    public static let title = "Threads"
    public static let emptyText = "No followed threads"

    /// The Threads row's symbol, the sidebar's unread-threads symbol, the
    /// follow states, the panel's close button and the two menu items.
    /// `ThreadSymbolTests` checks each one exists.
    static let rowSymbol = "bubble.left.and.text.bubble.right"
    static let unreadSymbol = "bubble.left.and.bubble.right.fill"
    static let followingSymbol = "checkmark"
    static let followSymbol = "plus"
    static let closeSymbol = "xmark"
    static let replySymbol = "arrowshape.turn.up.left"
    static let markUnreadSymbol = "envelope.badge"
    static let symbols = [
        rowSymbol, unreadSymbol, followingSymbol, followSymbol, closeSymbol, replySymbol, markUnreadSymbol
    ]

    /// The plain count, and no badge at zero, as the Mentions row.
    public static func badge(unread: Int) -> String? {
        unread > 0 ? "\(unread)" : nil
    }

    /// The sidebar's thread symbol: unread threads and nothing else unread.
    /// The dot keeps meaning top-level messages (spec §5.3), and a rule that
    /// hides unread hides this too.
    static func showsThreadSymbol(_ conversation: Conversation, hidden: Bool) -> Bool {
        !hidden && conversation.hasUnreadThread && !conversation.hasUnread
    }

    static func followTitle(isFollowed: Bool) -> String {
        isFollowed ? "Following" : "Follow"
    }

    /// The per-conversation gate (world field 27, §63.2): "Reply in Thread"
    /// and "Mark as Unread" only where the conversation has replies.
    static func offersReplies(in conversation: Conversation?) -> Bool {
        conversation?.repliesEnabled == true
    }
}
