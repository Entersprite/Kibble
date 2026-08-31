import ChatKit
import Foundation

/// One `ChatEvent` per case.
///
/// Hand-written rather than derived, for the reason `ChatKit`'s own coverage
/// lists give: deriving it would make the coverage test pass automatically the
/// moment a case is added, which is precisely when it needs to fail.
enum EventSamples {
    struct Sample: Sendable {
        let name: String
        let event: ChatEvent

        /// True only where reducing to nothing is the documented, intended
        /// behaviour. Anything else that reduces to nothing is a hole.
        var producesNothing = false
    }

    private static let conversation = Conversation.ID("space:1")
    private static let member = Member.ID("people/one")
    private static let messageID = Message.ID("msg:1")
    private static let at = Date(timeIntervalSince1970: 1_788_166_800)

    static let message = Message(
        id: messageID,
        conversationID: conversation,
        threadID: MessageThread.ID("topic:1"),
        sender: member,
        text: "hello",
        createdAt: at
    )

    static let all: [Sample] = [
        Sample(name: "connectionStateChanged", event: .connectionStateChanged(.connected)),
        Sample(
            name: "conversationsChanged",
            event: .conversationsChanged([Conversation(id: conversation, kind: .space)])
        ),
        Sample(
            name: "conversationUpdated",
            event: .conversationUpdated(Conversation(id: conversation, kind: .space))
        ),
        Sample(name: "messageReceived", event: .messageReceived(message)),
        Sample(name: "messageUpdated", event: .messageUpdated(message)),
        Sample(name: "messageDeleted", event: .messageDeleted(id: messageID, in: conversation)),
        Sample(
            name: "reactionChanged",
            event: .reactionChanged(
                messageID: messageID,
                reactions: [Reaction(emoji: "👍", count: 1, includesMe: false)]
            )
        ),
        Sample(
            name: "typingChanged",
            event: .typingChanged(conversationID: conversation, member: member, isTyping: true)
        ),
        Sample(
            name: "readStateChanged",
            event: .readStateChanged(conversationID: conversation, lastReadAt: at, unread: 2)
        ),
        Sample(
            name: "membersChanged",
            event: .membersChanged(
                conversationID: conversation,
                members: [Member(id: member, kind: .human, displayName: "One")]
            )
        ),
        Sample(name: "presenceChanged", event: .presenceChanged(member: member, presence: .active)),
        Sample(name: "gap", event: .gap(scope: .everything, reason: "buffer overflowed")),
        Sample(name: "backendError", event: .backendError(.sessionExpired)),
        Sample(
            name: "unknown",
            event: .unknown(type: "huddleStarted", payload: .object([:])),
            producesNothing: true
        )
    ]
}
