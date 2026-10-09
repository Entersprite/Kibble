import Foundation
@testable import ChatKit

/// The threads seam's values (threads spec §1), beside `Fixture` rather than
/// in it, because `Fixtures.swift` is near swiftlint's `file_length`.
extension Fixture {
    /// `message` as a reply: the same values, so `message-reply.json` differs
    /// from `message.json` by the one key.
    static let reply: Message = {
        var copy = message
        copy.isReply = true
        return copy
    }()

    /// Every field `MessageThread` gained, set, so the golden pins each key.
    /// `thread` keeps the shape from before threads.
    static let threadFull = MessageThread(
        id: threadID,
        conversationID: spaceID,
        replyCount: 4,
        lastActivity: editedAt,
        isFollowed: true,
        readPosition: createdAt,
        markedUnreadAt: editedAt,
        unreadCount: 2,
        recentRepliers: [botID, humanID],
        hasUnread: true
    )

    /// `dm` with replies on and an unread thread.
    static let conversationWithReplies = Conversation(
        id: dmID, kind: .directMessage, members: [humanID], repliesEnabled: true, hasUnreadThread: true
    )

    /// A thread fact from a newer backend, its discriminator kept in the
    /// payload as an unknown frame's is.
    static let unknownThreadChange = ThreadChange.unknown(
        type: "pinned",
        payload: .object(["type": .string("pinned"), "pinnedBy": .string(humanID.rawValue)])
    )
}
