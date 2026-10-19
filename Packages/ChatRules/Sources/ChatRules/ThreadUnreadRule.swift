import ChatKit
import Foundation

/// When a thread counts as followed, and when as unread (threads spec §4.2).
///
/// **Pure, and in `Reducer/`**, so the import scan that keeps the reducer
/// database-free covers it: a server deciding a thread's badge runs this
/// function, not a copy of it. The store calls it for every summary it reads
/// (`ChatStore.threadSummaries(in:)`), and nothing else decides either answer.
public enum ThreadUnreadRule {
    /// The stored setting, or, when nobody has said, whether the local user
    /// posted in the thread: posting follows a thread (`findings.md` §63.10,
    /// push 9 with 0).
    public static func isFollowed(_ thread: MessageThread, participated: Bool) -> Bool {
        thread.isFollowed ?? participated
    }

    /// Unread when it is marked unread, or when the server counts unread
    /// replies. **The server's count wins whenever there is one**, zero
    /// included.
    ///
    /// The fallback, while the count is unknown (history sends none until the
    /// owner's run confirms read state field 4, `findings.md` §64): followed,
    /// and a reply strictly newer than the read position, because equality is
    /// read (§42.2). **No read position is not unread**: nothing proves a reply
    /// is newer than what was read, and the threads the Threads list brings
    /// carry no read state.
    ///
    /// `newestReplyAt` is the newest reply someone else sent, never one of
    /// yours: your own reply is not unread to you. The caller passes it that way.
    public static func isUnread(_ thread: MessageThread, newestReplyAt: Date?, participated: Bool) -> Bool {
        if thread.markedUnreadAt != nil {
            return true
        }
        if let count = thread.unreadCount {
            return count > 0
        }
        guard isFollowed(thread, participated: participated),
              let newestReplyAt, let readPosition = thread.readPosition else { return false }
        return newestReplyAt > readPosition
    }
}
