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

    /// The tripwire: a read position *equal* to the newest message's create
    /// time is **read**. The 2026-09-28 probe found 59 conversations sitting
    /// exactly on the boundary, 45 of them Meet chats the owner never reads
    /// in GChat - positions Google's own clients wrote for their own reads
    /// (`findings.md` §42). §36.1's "equal does not cover" was measured
    /// through a store that kept milliseconds only, so the position it
    /// published was *below* the message. This answered `true` from
    /// 2026-09-23 (§37.9); a `>=` in `hasUnread` turns it red.
    @Test func aNewestMessageExactlyAtTheReadPositionIsRead() {
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
    /// An absent newest time reads as 0, and under `>` a zero head is later
    /// than no read position a real account holds, so the
    /// `hasLastHeadMessageCreateTimeUsec` guard is behaviourally redundant
    /// again, as it was before 2026-09-23 (session 24 §3.3): only a
    /// *negative* `last_read_time` could reach it. It stays because it says
    /// what an absent head means - no messages - rather than leaning on the
    /// comparison to happen to agree. Whether Chat ever sends a present
    /// `last_read_time` of 0 is unobserved.
    @Test func noNewestMessageIsNotUnread() {
        for lastRead: Int64 in [1000, 0] {
            let item = Fixture.item(groupID: Fixture.dmGroupID("d-1"), lastReadMicros: lastRead)
            #expect(Fixture.mapped(item)?.hasUnread == false, "lastRead \(lastRead)")
        }
    }
}
