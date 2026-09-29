import Foundation
import Testing
@testable import ChatKit

/// The values the golden files are made of.
///
/// Every timestamp is millisecond-aligned deliberately. RFC 3339 encoding here
/// is fixed at three fractional digits, so a `Date()` would not survive a round
/// trip and the resulting flake would be blamed on the coder rather than on the
/// test. `readAt` has no fractional part at all, which is what pins the
/// encoder's `.000` normalisation.
enum Fixture {
    static func date(_ raw: String) -> Date {
        guard let date = RFC3339.date(from: raw) else {
            preconditionFailure("fixture timestamp is not RFC 3339: \(raw)")
        }
        return date
    }

    static let createdAt = date("2026-08-30T10:15:30.123Z")
    static let editedAt = date("2026-08-30T11:00:00.500Z")
    static let readAt = date("2026-08-30T12:00:00Z")

    static let spaceID = Conversation.ID("space:AAAA1111")
    static let dmID = Conversation.ID("dm:BBBB2222")
    static let humanID = Member.ID("users/1001")
    static let botID = Member.ID("users/9000")
    static let threadID = MessageThread.ID("space:AAAA1111|topic-77")
    static let messageID = Message.ID("space:AAAA1111|topic-77|msg-5")

    static let human = Member(
        id: humanID,
        kind: .human,
        displayName: "Ada Lovelace",
        email: "ada@example.com",
        avatarURL: URL(string: "https://example.com/ada.png"),
        presence: .active
    )

    /// An app has no display name anywhere in the API, and its presence is a
    /// value this build does not model — both of which the seam has to survive.
    static let bot = Member(id: botID, kind: .app, presence: .unknown("SHARING_DISABLED"))

    /// What `get_self_user_status` actually returns: an id and a kind, never a
    /// name. Deliberately not `human` above, which carries a full profile - a
    /// `selfIdentified` sample that looked like every other member fixture
    /// would hide the one property this event is honest about.
    static let localUser = Member(id: humanID, kind: .human)

    static let reaction = Reaction(emoji: "🛞", count: 3, includesMe: true)

    static let attachment = Attachment(
        id: "attachment-data-ref-1",
        name: "invoice.pdf",
        contentType: "application/pdf",
        byteSize: 84213,
        downloadURL: URL(string: "https://example.com/download/1"),
        thumbnailURL: URL(string: "https://example.com/thumb/1")
    )

    static let conversation = Conversation(
        id: spaceID,
        kind: .space,
        title: "Ops Team",
        avatarURL: URL(string: "https://example.com/space.png"),
        lastActivity: createdAt,
        unreadCount: 3,
        // `true` here so the goldens pin both sides of `hasUnread`; every
        // other conversation fixture leaves it at its `false` default.
        hasUnread: true,
        isMuted: true,
        notificationLevel: .lessWithNewThreads,
        members: [humanID, botID],
        // Deliberately not `members.count`: the count is the server's total,
        // and the listed members are often none of it (a space lists nobody).
        memberCount: 14,
        isThreaded: true
    )

    static let dm = Conversation(id: dmID, kind: .directMessage, members: [humanID])

    /// Exists so `Kind.meetChat`'s **wire token** has a golden file. Renaming
    /// the case without renaming the token, or the reverse, then shows up as a
    /// diff instead of silently changing the wire format.
    static let meetChat = Conversation(
        id: spaceID,
        kind: .meetChat,
        title: "Engineering Review - Sep 8",
        lastActivity: createdAt,
        members: [humanID]
    )

    /// Exists so `readPosition`'s key has a golden. Every other conversation
    /// fixture leaves it `nil`, which is what keeps their goldens unchanged.
    static let conversationWithReadPosition = Conversation(
        id: dmID, kind: .directMessage, members: [humanID], readPosition: readAt
    )

    static let thread = MessageThread(
        id: threadID,
        conversationID: spaceID,
        replyCount: 4,
        lastActivity: editedAt
    )

    static let message = Message(
        id: messageID,
        conversationID: spaceID,
        threadID: threadID,
        sender: humanID,
        text: "Ordered the 225/45R17s.",
        createdAt: createdAt,
        editedAt: editedAt,
        isDeleted: false,
        reactions: [reaction],
        attachments: [attachment],
        localID: "draft-42"
    )

    /// `Fixture.message` with two mentions. Both spans are checked against
    /// the exact string they claim to span: "@Dana" is `start: 0, length: 5`
    /// and "@all" is `start: 30, length: 4`.
    static let messageWithMentions: Message = {
        var copy = message
        copy.text = "@Dana ordered the 225/45R17s. @all"
        copy.mentions = [
            Mention(target: .user(humanID), start: 0, length: 5),
            Mention(target: .all, start: 30, length: 4)
        ]
        return copy
    }()

    static let capabilities = Capabilities(
        canSendMessages: true,
        canEditMessages: true,
        canReact: true,
        canSendTypingState: true,
        receivesTypingState: true,
        canMarkRead: true,
        supportsThreads: true,
        extendedFlags: ["voiceRooms", "customEmoji"]
    )

    /// A payload with one of every JSON type in it, used wherever an unknown
    /// frame has to be shown surviving verbatim.
    static let unknownPayload = JSONValue.object([
        "type": .string("somethingNewer"),
        "count": .number(7),
        "ratio": .number(0.5),
        "flag": .bool(true),
        "nothing": .null,
        "items": .array([.string("a"), .number(1), .null]),
        "nested": .object(["deep": .string("value")])
    ])
}

// MARK: - Every case of the two frame enums

extension Fixture {
    /// One sample per `ChatEvent` case. The count is asserted in the test
    /// suite, so adding a case without adding a sample fails rather than
    /// quietly going untested.
    static let events: [Sample<ChatEvent>] = [
        Sample(
            "event-connectionStateChanged",
            .connectionStateChanged(.reconnecting(attempt: 2, issue: nil, detail: nil))
        ),
        Sample("event-selfIdentified", .selfIdentified(localUser)),
        Sample("event-conversationsChanged", .conversationsChanged([conversation, dm])),
        Sample("event-conversationUpdated", .conversationUpdated(conversation)),
        Sample("event-messageReceived", .messageReceived(message)),
        Sample("event-messageUpdated", .messageUpdated(message)),
        Sample("event-messageDeleted", .messageDeleted(id: messageID, in: spaceID)),
        Sample("event-reactionChanged", .reactionChanged(messageID: messageID, reactions: [reaction])),
        Sample(
            "event-typingChanged",
            .typingChanged(conversationID: spaceID, member: humanID, isTyping: true)
        ),
        Sample(
            "event-readStateChanged",
            .readStateChanged(conversationID: spaceID, lastReadAt: readAt, unread: 0)
        ),
        Sample("event-membersChanged", .membersChanged(conversationID: spaceID, members: [human, bot])),
        Sample("event-membersResolved", .membersResolved([human, bot])),
        Sample("event-presenceChanged", .presenceChanged(member: botID, presence: .doNotDisturb)),
        Sample("event-gap", .gap(scope: .conversation(spaceID), reason: "event buffer overflow")),
        Sample("event-backendError", .backendError(.rateLimited(retryAfter: .milliseconds(1500)))),
        Sample("event-unknown", .unknown(type: "somethingNewer", payload: unknownPayload))
    ]

    /// One sample per `ChatCommand` case, same contract.
    static let commands: [Sample<ChatCommand>] = [
        Sample(
            "command-sendMessage",
            .sendMessage(
                conversationID: spaceID,
                threadID: threadID,
                text: "On it.",
                localID: "draft-43"
            )
        ),
        Sample(
            "command-sendMessage-newThread",
            .sendMessage(conversationID: dmID, threadID: nil, text: "Hello.", localID: nil)
        ),
        Sample("command-editMessage", .editMessage(id: messageID, text: "Corrected.")),
        Sample("command-deleteMessage", .deleteMessage(id: messageID)),
        Sample("command-setReaction", .setReaction(messageID: messageID, emoji: "🛞", add: true)),
        Sample(
            "command-setTyping",
            .setTyping(conversationID: spaceID, threadID: threadID, isTyping: false)
        ),
        Sample("command-markRead", .markRead(conversationID: spaceID, upTo: readAt)),
        Sample(
            "command-setNotificationLevel",
            .setNotificationLevel(conversationID: spaceID, level: .never)
        ),
        Sample("command-watchPresence", .watchPresence(members: [humanID, botID])),
        Sample("command-unknown", .unknown(type: "somethingNewer", payload: unknownPayload))
    ]

    static let errors: [Sample<ChatError>] = [
        Sample("error-notAuthenticated", .notAuthenticated),
        Sample("error-sessionExpired", .sessionExpired),
        Sample("error-rateLimited", .rateLimited(retryAfter: .milliseconds(2500))),
        Sample("error-rateLimited-noHint", .rateLimited(retryAfter: nil)),
        Sample("error-unsupported", .unsupported(capability: "canEditMessages")),
        Sample("error-transport", .transport("connection reset")),
        Sample("error-decoding", .decoding("unexpected field")),
        Sample("error-server", .server(status: 503, message: "backend unavailable")),
        Sample("error-unknown", .unknown("quotaExceeded"))
    ]

    static let connectionStates: [Sample<ConnectionState>] = [
        Sample("state-idle", .idle),
        Sample("state-connecting", .connecting),
        Sample("state-connected", .connected),
        Sample("state-reconnecting", .reconnecting(attempt: 7, issue: nil, detail: nil)),
        Sample("state-disconnected", .disconnected(reason: "long poll closed", issue: nil)),
        Sample("state-disconnected-deliberate", .disconnected(reason: nil, issue: nil)),
        Sample("state-unknown", .unknown("somethingNewer"))
    ]

    static let gapScopes: [Sample<GapScope>] = [
        Sample("scope-everything", .everything),
        Sample("scope-conversation", .conversation(spaceID))
    ]
}
