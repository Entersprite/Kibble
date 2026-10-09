import ChatKit

/// What the Threads row, the list and the sidebar say. Pure, so every state is
/// a test.
public enum ThreadsPresentation {
    public static let title = "Threads"
    public static let emptyText = "No followed threads"

    /// The Threads row's symbol, the follow states, the panel's close button
    /// and the two menu items. `ThreadSymbolTests` checks each one exists.
    static let rowSymbol = "bubble.left.and.text.bubble.right"
    static let followingSymbol = "checkmark"
    static let followSymbol = "plus"
    static let closeSymbol = "xmark"
    static let replySymbol = "arrowshape.turn.up.left"
    static let markUnreadSymbol = "envelope.badge"
    static let symbols = [
        rowSymbol, followingSymbol, followSymbol, closeSymbol, replySymbol, markUnreadSymbol
    ]

    /// Whether a thread has a reply: `replyCount` counts the first message.
    /// The mark asks this, and so does "Reply in Thread", which a thread with
    /// replies does not offer because its mark opens them.
    static func hasReplies(_ thread: MessageThread?) -> Bool {
        (thread?.replyCount ?? 0) > 1
    }

    /// The plain count, and no badge at zero, as the Mentions row.
    public static func badge(unread: Int) -> String? {
        unread > 0 ? "\(unread)" : nil
    }

    /// The sidebar's dot and bold name: a top-level unread, or activity in a
    /// followed thread (owner, session 58, replacing spec §5.3's thread
    /// symbol). `unreadThreads` is `ThreadSceneState.unreadConversations`, the
    /// badge's own read. **`hasUnreadThread` is not read**: the server's flag
    /// may cover unfollowed threads (`[Verify]`, `findings.md` §64). A rule
    /// that hides unread hides both.
    static func showsUnread(
        _ conversation: Conversation, hidden: Bool, unreadThreads: Set<Conversation.ID>
    ) -> Bool {
        !hidden && (conversation.hasUnread || unreadThreads.contains(conversation.id))
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
