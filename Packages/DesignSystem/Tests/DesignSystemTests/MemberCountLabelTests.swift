import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// The window header's subtitle. It used to be `members.count`, which reads
/// "0 members" on every named space, because a space lists nobody on the
/// world response (`findings.md` §37.5). It now shows the server's count or
/// nothing.
struct MemberCountLabelTests {
    private func conversation(_ kind: Conversation.Kind, count: Int?, listed: Int = 0) -> Conversation {
        Conversation(
            id: Conversation.ID("space:1"),
            kind: kind,
            members: (0 ..< listed).map { Member.ID("u-\($0)") },
            memberCount: count
        )
    }

    @Test func aSpaceShowsTheServersCountNotItsList() {
        #expect(Display.memberCountLabel(of: conversation(.space, count: 14, listed: 0)) == "14 members")
    }

    @Test func oneIsSingular() {
        #expect(Display.memberCountLabel(of: conversation(.meetChat, count: 1)) == "1 member")
    }

    /// The bug itself: no count must never become "0 members".
    @Test func noCountShowsNothingEvenWithMembersListed() {
        #expect(Display.memberCountLabel(of: conversation(.space, count: nil)) == nil)
        #expect(Display.memberCountLabel(of: conversation(.groupDirectMessage, count: nil, listed: 3)) == nil)
    }

    /// A one-to-one conversation has two people by definition; saying so is noise.
    @Test func aDirectMessageShowsNothing() {
        #expect(Display.memberCountLabel(of: conversation(.directMessage, count: 2, listed: 2)) == nil)
        #expect(Display.memberCountLabel(of: conversation(.appDirectMessage, count: 2, listed: 2)) == nil)
    }

    @Test func aGroupChatAndAnUnknownKindShowTheirCount() {
        #expect(Display
            .memberCountLabel(of: conversation(.groupDirectMessage, count: 4, listed: 3)) == "4 members")
        #expect(Display.memberCountLabel(of: conversation(.unknown("huddle"), count: 5)) == "5 members")
    }
}
