import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// Which status is drawn, and in what words.
struct StatusDisplayTests {
    private let me = Member.ID("me")
    private let ada = Member.ID("u-1")
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func directory(_ status: MemberStatus?) -> [Member.ID: Member] {
        [
            ada: Member(id: ada, kind: .human, displayName: "Ada", presence: .inactive, status: status),
            me: Member(id: me, kind: .human, displayName: "Me", status: MemberStatus(emoji: "🏠"))
        ]
    }

    private func shown(
        _ status: MemberStatus?,
        of member: Member.ID? = nil,
        me: Member.ID? = Member.ID("me"),
        connection: ConnectionState = .connected
    ) -> MemberStatus? {
        Display.status(
            of: member ?? ada, directory: directory(status), me: me, connection: connection, now: now
        )
    }

    @Test func aStatusIsShown() {
        let status = MemberStatus(emoji: "🌴", text: "On vacation", expiresAt: now.addingTimeInterval(60))
        #expect(shown(status) == status)
    }

    /// Past its expiry it is no longer true, whatever the last poll said.
    @Test func anExpiredStatusIsNot() {
        #expect(shown(MemberStatus(emoji: "🌴", expiresAt: now)) == nil)
        #expect(shown(MemberStatus(emoji: "🌴", expiresAt: now.addingTimeInterval(-1))) == nil)
    }

    @Test func nothingWhileDisconnectedForYouOrUntilYouAreKnown() {
        let status = MemberStatus(emoji: "🌴")
        #expect(shown(status, connection: .connecting) == nil)
        #expect(shown(status, of: me) == nil)
        #expect(shown(status, me: nil) == nil)
    }

    @Test func anEmptyStatusIsNothing() {
        #expect(shown(MemberStatus()) == nil)
    }

    /// A DM row shows the other person's; nothing else has one person.
    @Test func aConversationShowsItsOtherPersonsInADirectMessageOnly() {
        let status = MemberStatus(emoji: "🌴")
        func of(_ kind: Conversation.Kind) -> MemberStatus? {
            Display.status(
                of: Conversation(id: Conversation.ID("dm/1"), kind: kind, members: [me, ada]),
                directory: directory(status), me: me, connection: .connected, now: now
            )
        }
        #expect(of(.directMessage) == status)
        #expect(of(.groupDirectMessage) == nil)
        #expect(of(.space) == nil)
    }

    @Test func theWords() {
        #expect(Display.statusSummary(MemberStatus(emoji: "🌴", text: "On vacation")) == "🌴 On vacation")
        #expect(Display
            .statusSummary(MemberStatus(customEmojiShortcode: ":parrot:", text: "Shipped")) ==
            ":parrot: Shipped")
        #expect(Display.statusSummary(MemberStatus(emoji: "🤒")) == "🤒")
        #expect(Display.headerSubtitle(
            presence: .inactive,
            status: MemberStatus(emoji: "🌴", text: "On vacation")
        )
            == "Away · 🌴 On vacation")
        #expect(Display.headerSubtitle(presence: nil, status: MemberStatus(text: "Lunch")) == "Lunch")
        #expect(Display.headerSubtitle(presence: .active, status: nil) == "Active")
        #expect(Display.headerSubtitle(presence: nil, status: nil) == nil)
    }
}
