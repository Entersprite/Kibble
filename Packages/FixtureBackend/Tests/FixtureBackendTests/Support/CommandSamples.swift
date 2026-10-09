import ChatKit
import Foundation

/// One `ChatCommand` per case, with the `Capabilities` flag whose absence must
/// make it fail.
///
/// Written out by hand rather than derived. A derived list would start passing
/// the moment a case was added, which is precisely the moment it needs to fail
/// - the same reasoning `ChatKit`'s frame coverage lists give.
enum CommandSamples {
    struct Sample: Sendable, CustomStringConvertible {
        let name: String
        let command: ChatCommand

        /// The name that must come back in `ChatError.unsupported(capability:)`.
        /// For an unknown command that is the command's own type, because there
        /// is no flag to point at.
        let capability: String

        var description: String {
            name
        }
    }

    private static let dm = Conversation.ID("dm:1")
    private static let space = Conversation.ID("space:1")
    private static let seed = Message.ID("fixture-seed-1")

    static let all: [Sample] = [
        Sample(
            name: "sendMessage",
            command: .sendMessage(conversationID: dm, threadID: nil, text: "x", localID: nil),
            capability: "canSendMessages"
        ),
        Sample(
            name: "editMessage",
            command: .editMessage(id: seed, text: "x"),
            capability: "canEditMessages"
        ),
        Sample(
            name: "deleteMessage",
            command: .deleteMessage(id: seed),
            capability: "canDeleteMessages"
        ),
        Sample(
            name: "setReaction",
            command: .setReaction(messageID: seed, emoji: "👍", add: true),
            capability: "canReact"
        ),
        Sample(
            name: "setTyping",
            command: .setTyping(conversationID: dm, threadID: nil, isTyping: true),
            capability: "canSendTypingState"
        ),
        Sample(
            name: "markRead",
            command: .markRead(conversationID: space, upTo: Date(timeIntervalSince1970: 0)),
            capability: "canMarkRead"
        ),
        Sample(
            name: "setNotificationLevel",
            command: .setNotificationLevel(conversationID: space, level: .never),
            capability: "canSetNotificationLevel"
        ),
        Sample(
            name: "setStatus",
            command: .setStatus(MemberStatus(text: "x")),
            capability: "canSetStatus"
        ),
        Sample(
            name: "setAvailability",
            command: .setAvailability(.away),
            capability: "canSetStatus"
        ),
        Sample(
            name: "markThreadRead",
            command: .markThreadRead(
                conversationID: space, threadID: MessageThread.ID("fixture-seed-topic-3"),
                upTo: Date(timeIntervalSince1970: 0)
            ),
            capability: "supportsThreads"
        ),
        Sample(
            name: "setThreadUnreadMark",
            command: .setThreadUnreadMark(
                conversationID: space, threadID: MessageThread.ID("fixture-seed-topic-3"), at: nil
            ),
            capability: "supportsThreads"
        ),
        Sample(
            name: "unknown",
            command: .unknown(type: "someFutureCommand", payload: .object([:])),
            capability: "someFutureCommand"
        )
    ]
}
