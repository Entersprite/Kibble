import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The three reads `WorldMapping.swift` gained after session 23: a group
/// chat's members and title from `name_users` (`findings.md` §37.6), and
/// `hasUnread` from the read-state timestamp pair (§37.8).
///
/// Each test was checked by deleting or inverting the branch it names; the
/// one exception is stated where it occurs.
struct WorldMappingNameUsersAndUnreadTests {
    private typealias Fixture = WorldItemFixture

    // MARK: - Members

    /// The measured group-chat shape: no `dm_members` at all. Before §37.6 this
    /// produced an empty member list and a sidebar row reading `space/…`.
    @Test func aGroupChatsMembersComeFromNameUsers() {
        let item = Fixture.item(groupID: Fixture.spaceGroupID("s-1"), nameUsers: ["u-1", "u-2", "u-3"])
        #expect(
            Fixture.mapped(item)?.members
                == [ChatKit.Member.ID("u-1"), ChatKit.Member.ID("u-2"), ChatKit.Member.ID("u-3")]
        )
    }

    /// Synthetic: no real item carries both. Pins which one wins.
    @Test func dmMembersWinOverNameUsersWhenBothArrive() {
        let item = Fixture.item(
            groupID: Fixture.dmGroupID("d-1"), dmMembers: ["u-1", "u-2"], nameUsers: ["u-9"]
        )
        #expect(Fixture.mapped(item)?.members == [ChatKit.Member.ID("u-1"), ChatKit.Member.ID("u-2")])
    }

    // MARK: - Title

    /// Whether Chat ever sends `name_users.group_name` is unobserved (§37.6);
    /// this pins what happens if it does.
    @Test func aNameUsersGroupNameTitlesAConversationWithNoRoomName() {
        let item = Fixture.item(
            groupID: Fixture.spaceGroupID("s-1"), nameUsers: ["u-1", "u-2"], groupName: "Trip planning"
        )
        #expect(Fixture.mapped(item)?.title == "Trip planning")
    }

    @Test func aRoomNameBeatsANameUsersGroupName() {
        let item = Fixture.item(
            groupID: Fixture.spaceGroupID("s-1"),
            roomName: "Design",
            nameUsers: ["u-1"],
            groupName: "Something else"
        )
        #expect(Fixture.mapped(item)?.title == "Design")
    }

    /// The measured group-chat shape, and the guard that matters most here:
    /// without `hasGroupName`, every group chat gets `""` - which
    /// `Conversation.title` defines as "the server sent a title", so the row
    /// renders blank instead of deriving "A, B, C" from its members.
    @Test func nameUsersWithoutAGroupNameLeavesTheTitleNil() {
        let item = Fixture.item(groupID: Fixture.spaceGroupID("s-1"), nameUsers: ["u-1", "u-2"])
        #expect(Fixture.mapped(item)?.title == nil)
    }

    // MARK: - hasUnread: the newest message against the read position

    @Test func aNewestMessageAfterTheReadPositionIsUnread() {
        let item = Fixture.item(
            groupID: Fixture.dmGroupID("d-1"), lastReadMicros: 1000, newestMessageMicros: 1001
        )
        #expect(Fixture.mapped(item)?.hasUnread == true)
    }

    /// **Pins current behaviour, which contradicts `findings.md` §36.** §36
    /// measured that a read position *equal* to a message's create time does
    /// **not** cover it - so at equality the newest message is unread by
    /// Google's rule, and `hasUnread` answers `false`. `WorldMapping`'s own
    /// doc comment says it applies §36's relation; at this one point it
    /// applies the opposite. `[Verify]` whether the world's
    /// `last_read_time` pair follows the receipt boundary at all - but it is
    /// the only boundary anything here has measured.
    ///
    /// Left as-is on purpose, pending the owner (session 24 §3): this is a
    /// tripwire, so the flip to `>=` has to change this test in the same edit
    /// rather than slip through a green suite.
    @Test func aNewestMessageExactlyAtTheReadPositionIsCurrentlyRead() {
        let item = Fixture.item(
            groupID: Fixture.dmGroupID("d-1"), lastReadMicros: 1000, newestMessageMicros: 1000
        )
        #expect(Fixture.mapped(item)?.hasUnread == false)
    }

    @Test func aNewestMessageBeforeTheReadPositionIsRead() {
        let item = Fixture.item(
            groupID: Fixture.dmGroupID("d-1"), lastReadMicros: 1001, newestMessageMicros: 1000
        )
        #expect(Fixture.mapped(item)?.hasUnread == false)
    }

    /// Unobserved: `last_read_time` arrived on all 220 real items. Pins the
    /// reading that claims least - no read position is not evidence of
    /// unread messages.
    @Test func noReadPositionIsNotUnread() {
        let item = Fixture.item(groupID: Fixture.dmGroupID("d-1"), newestMessageMicros: 1001)
        #expect(Fixture.mapped(item)?.hasUnread == false)
    }

    /// Measured on 3 of 220 real items, presumably conversations with no
    /// messages.
    ///
    /// **This test does not cover the `hasLastHeadMessageCreateTimeUsec`
    /// guard, and cannot.** With the guard deleted, an absent field reads as
    /// 0, and 0 is never greater than a real read position, so the answer is
    /// the same. The guard is behaviourally redundant for any non-negative
    /// timestamp; it stays as a statement of intent. This test pins the
    /// behaviour for a shape that really arrives, not the guard.
    @Test func noNewestMessageIsNotUnread() {
        let item = Fixture.item(groupID: Fixture.dmGroupID("d-1"), lastReadMicros: 1000)
        #expect(Fixture.mapped(item)?.hasUnread == false)
    }
}
