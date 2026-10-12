import ChatKit
import Foundation
import GRDB

extension ChatStore {
    /// Read state and the unread flag - the two writes that move `hasUnread`.
    ///
    /// Split from `performConversationWrite(_:in:)` because adding
    /// `.markUnread` took that function to `swiftlint`'s cyclomatic-complexity
    /// limit of 10. It is a real seam rather than an arbitrary cut: these two
    /// are the **only** writes that touch `hasUnread`, and they are the pair
    /// that has to stay consistent - the flag shipped with nothing clearing it
    /// (`findings.md` §37.8), so keeping them adjacent is the point.
    static func performReadWrite(_ write: StoreWrite, in db: Database) throws {
        switch write {
        case let .setReadState(conversation, lastReadAt, unread):
            // A forward read clears the dot. A backward read is the web
            // client's Mark as unread: the newest message may not be in our
            // local history yet, so comparing against stored messages would
            // miss precisely the conversation the user marked unread.
            //
            // The position is bound through `StoredDate`, never as the `Date`
            // itself: a bound `Date` is GRDB's millisecond text whatever the
            // records' strategy says, which would truncate the watermark and
            // leave a text value in a column of numbers.
            try db.execute(
                sql: """
                UPDATE conversation
                SET unreadCount = ?, lastReadAt = ?,
                    hasUnread = CASE WHEN markedUnreadAt IS NOT NULL OR lastReadAt > ? THEN 1 ELSE 0 END
                WHERE id = ?
                """,
                arguments: [
                    unread, StoredDate.value(lastReadAt), StoredDate.value(lastReadAt), conversation.rawValue
                ]
            )
        case let .markUnread(conversation, sender):
            // The local user's own message never marks their conversation
            // unread - see `StoreWrite.markUnread`'s doc comment for why the
            // comparison happens here rather than in the reducer.
            let localMember = try String.fetchOne(
                db, sql: "SELECT localMemberID FROM syncState WHERE id = 1"
            )
            guard localMember != sender.rawValue else { break }
            try db.execute(
                sql: "UPDATE conversation SET hasUnread = 1 WHERE id = ?",
                arguments: [conversation.rawValue]
            )
        default:
            // `perform(_:in:)` routes only the two cases above here. Kept
            // rather than made exhaustive because `StoreWrite` gains cases
            // often, and each one should be a decision in `perform(_:in:)`
            // rather than a compile error in every branch function.
            break
        }
    }
}
