import ChatKit
import Foundation

/// One thing the world does to a client.
///
/// `ChatCommand` is the client asking for something; this is the other
/// direction - someone else typing, a message arriving, the channel dropping,
/// catch-up giving up. A script is the server's half of a conversation, and
/// writing one is how a test or a demo stages a situation that would otherwise
/// need a real account and a colleague.
///
/// Steps do not consult the client's connection state, because a server does
/// not know or care whether the client thinks it is connected.
public enum FixtureStep: Sendable, Hashable {
    /// A message from someone. `thread` is `nil` to start a new topic, which
    /// in a flat conversation is the only case there is. A thread names a
    /// topic the world already holds, and the message arrives as a reply
    /// (`Message.isReply`), counted against its thread rather than its
    /// conversation (threads spec §4.3).
    case incomingMessage(
        conversation: Conversation.ID,
        from: Member.ID,
        text: String,
        thread: MessageThread.ID?
    )

    case editMessage(id: Message.ID, text: String)
    case deleteMessage(id: Message.ID)
    case reaction(messageID: Message.ID, emoji: String, by: Member.ID, add: Bool)
    case typing(conversation: Conversation.ID, member: Member.ID, isTyping: Bool)
    case presence(member: Member.ID, presence: Presence)

    /// Read state changed somewhere else - another device, or the web client.
    case readState(conversation: Conversation.ID, unread: Int)

    case gap(scope: GapScope, reason: String)

    /// The channel went away. Unlike `disconnect()`, this carries a reason and
    /// is not something the client asked for.
    case drop(reason: String)

    case reconnecting(attempt: Int)
    case error(ChatError)

    /// Wall-clock pause. **Ignored** when a script is played by a test and
    /// honoured only by `FixtureDemoDriver`, which is the entire difference
    /// between the two layers.
    case delay(Duration)
}

/// An ordered list of steps.
public struct FixtureScript: Sendable, Hashable {
    public var steps: [FixtureStep]

    public init(steps: [FixtureStep]) {
        self.steps = steps
    }
}

public extension FixtureScript {
    /// One of every step, against `FixtureWorld.minimal`.
    ///
    /// Exists for the determinism test, which needs a run that touches every
    /// code path that could smuggle in a clock or a random identifier. Adding a
    /// `FixtureStep` case without adding it here weakens that test, so treat
    /// this as part of the case's definition.
    static let smokeTest = FixtureScript(steps: [
        .incomingMessage(
            conversation: Conversation.ID("dm:1"),
            from: Member.ID("fixture-other"),
            text: "and one more thing",
            thread: nil
        ),
        .editMessage(id: Message.ID("fixture-seed-1"), text: "morning - did it finish?"),
        .reaction(
            messageID: Message.ID("fixture-seed-3"),
            emoji: "👍",
            by: Member.ID("fixture-other"),
            add: true
        ),
        .typing(
            conversation: Conversation.ID("space:1"),
            member: Member.ID("fixture-other"),
            isTyping: true
        ),
        .typing(
            conversation: Conversation.ID("space:1"),
            member: Member.ID("fixture-other"),
            isTyping: false
        ),
        .presence(member: Member.ID("fixture-other"), presence: .inactive),
        .readState(conversation: Conversation.ID("space:1"), unread: 0),
        .deleteMessage(id: Message.ID("fixture-seed-2")),
        .gap(scope: .conversation(Conversation.ID("dm:1")), reason: "catch-up aborted"),
        .error(.rateLimited(retryAfter: .seconds(30))),
        .delay(.milliseconds(1)),
        .drop(reason: "server closed the channel"),
        .reconnecting(attempt: 1)
    ])
}
