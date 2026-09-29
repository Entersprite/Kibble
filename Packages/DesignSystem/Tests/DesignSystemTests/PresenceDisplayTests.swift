import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// Which conversation shows a presence, when, and in what words.
struct PresenceDisplayTests {
    private let me = Member.ID("me")
    private let ada = Member.ID("u-1")

    private func directory(_ presence: Presence?) -> [Member.ID: Member] {
        [
            ada: Member(id: ada, kind: .human, displayName: "Ada", presence: presence),
            me: Member(id: me, kind: .human, displayName: "Me", presence: .active)
        ]
    }

    private func conversation(_ kind: Conversation.Kind) -> Conversation {
        Conversation(id: Conversation.ID("dm/1"), kind: kind, members: [me, ada])
    }

    private func shown(
        _ presence: Presence?,
        in kind: Conversation.Kind = .directMessage,
        connection: ConnectionState = .connected
    ) -> Presence? {
        Display.presence(
            of: conversation(kind), directory: directory(presence), me: me, connection: connection
        )
    }

    /// The other person's, never the local user's own - who is `.active`
    /// here, so a lookup that picked the wrong member would show it.
    @Test func aDirectMessageShowsTheOtherPersonsPresence() {
        #expect(shown(.inactive) == .inactive)
        #expect(shown(.doNotDisturb) == .doNotDisturb)
    }

    @Test func nothingForAnythingButAOneToOneDirectMessage() {
        for kind: Conversation.Kind in [.groupDirectMessage, .appDirectMessage, .space, .meetChat] {
            #expect(shown(.active, in: kind) == nil)
        }
    }

    /// A claim about now, so nothing while the session is not live.
    @Test func nothingUnlessConnected() {
        let offline: [ConnectionState] = [
            .idle, .connecting, .reconnecting(attempt: 1, issue: nil, detail: nil),
            .disconnected(reason: nil, issue: nil)
        ]
        for connection in offline {
            #expect(shown(.active, connection: connection) == nil)
        }
    }

    /// "Nobody told us" and "we cannot name it" both draw nothing.
    @Test func nothingForNoPresenceOrAnUnknownOne() {
        #expect(shown(nil) == nil)
        #expect(shown(.unknown("SHARING_DISABLED")) == nil)
    }

    @Test func theHeaderWords() {
        #expect(Display.presenceLabel(.active) == "Active")
        #expect(Display.presenceLabel(.inactive) == "Away")
        #expect(Display.presenceLabel(.doNotDisturb) == "Do not disturb")
        #expect(Display.presenceLabel(.unknown("x")) == nil)
    }
}
