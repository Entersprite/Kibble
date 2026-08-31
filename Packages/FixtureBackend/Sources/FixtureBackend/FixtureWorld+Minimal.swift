import ChatKit
import Foundation

public extension FixtureWorld {
    /// The world the test suite runs against: two people, one DM, one threaded
    /// space, four messages.
    ///
    /// Separate from the demo world on purpose. Tests asserting on counts and
    /// ordering would otherwise break every time someone made the demo more
    /// convincing, and a test that breaks for a reason unrelated to its subject
    /// gets deleted rather than fixed.
    static let minimal: FixtureWorld = {
        let me = Member.ID("fixture-me")
        let other = Member.ID("fixture-other")
        let dm = Conversation.ID("dm:1")
        let space = Conversation.ID("space:1")
        let start = Date(timeIntervalSince1970: 1_788_166_800) // 2026-08-31T09:00:00Z
        func at(_ minutes: Int) -> Date {
            start.addingTimeInterval(Double(minutes) * 60)
        }

        let messages = [
            Message(
                id: Message.ID("fixture-seed-1"),
                conversationID: dm,
                threadID: MessageThread.ID("fixture-seed-topic-1"),
                sender: other,
                text: "Morning - did the overnight run finish?",
                createdAt: at(0)
            ),
            Message(
                id: Message.ID("fixture-seed-2"),
                conversationID: dm,
                threadID: MessageThread.ID("fixture-seed-topic-2"),
                sender: me,
                text: "It did. 41k rows, nothing flagged.",
                createdAt: at(3)
            ),
            Message(
                id: Message.ID("fixture-seed-3"),
                conversationID: space,
                threadID: MessageThread.ID("fixture-seed-topic-3"),
                sender: other,
                text: "Putting the variance list on the dashboard before standup.",
                createdAt: at(5)
            ),
            Message(
                id: Message.ID("fixture-seed-4"),
                conversationID: space,
                threadID: MessageThread.ID("fixture-seed-topic-3"),
                sender: me,
                text: "Thanks - I will read it on the way in.",
                createdAt: at(6)
            )
        ]

        return FixtureWorld(
            me: me,
            members: [
                Member(id: me, kind: .human, displayName: "Fixture User", email: "me@example.invalid"),
                Member(
                    id: other,
                    kind: .human,
                    displayName: "Other Person",
                    email: "other@example.invalid",
                    presence: .active
                )
            ],
            conversations: [
                Conversation(
                    id: dm,
                    kind: .directMessage,
                    // nil, not "": a DM has no server-provided title, and the
                    // client derives one. An empty string would be a title the
                    // server really sent - a different thing entirely.
                    title: nil,
                    lastActivity: at(3),
                    members: [me, other]
                ),
                Conversation(
                    id: space,
                    kind: .space,
                    title: "fixture-space",
                    lastActivity: at(6),
                    unreadCount: 1,
                    members: [me, other],
                    isThreaded: true
                )
            ],
            messages: messages,
            startedAt: at(6)
        )
    }()
}
