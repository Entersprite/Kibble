import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `PaginatedWorldResponse` becoming `[Conversation]`.
///
/// Built directly as `SwiftProtobuf` values rather than hand-encoded wire
/// bytes - `WorldItemLite` and `PaginatedWorldResponse` are ordinary generated
/// structs, and `WorldMapping` is exercised after `ProtoAPIClient` has already
/// done a typed decode, so there is no pblite layer to fight the way
/// `ChannelEventMappingTests` does.
struct WorldMappingTests {
    // MARK: - Building fixtures in the shape the proto actually uses

    private func spaceGroupID(_ id: String) -> GroupId {
        var group = GroupId()
        var space = SpaceId()
        space.spaceID = id
        group.spaceID = space
        return group
    }

    private func dmGroupID(_ id: String) -> GroupId {
        var group = GroupId()
        var dm = DmId()
        dm.dmID = id
        group.dmID = dm
        return group
    }

    private func userID(_ id: String) -> UserId {
        var user = UserId()
        user.id = id
        return user
    }

    private enum Threading {
        case threadedGroup
        case flatGroup
        case neither(groupLiteIsFlat: Bool)
        /// None of `threaded_group`, `flat_group` or `group_lite` set at all -
        /// distinct from `.neither`, which always sets `group_lite`.
        case none
    }

    private func item(
        groupID: GroupId,
        roomName: String? = nil,
        avatarURL: String? = nil,
        sortTimestampMicros: Int64? = nil,
        unreadCount: Int64 = 0,
        members: [String] = [],
        threading: Threading = .neither(groupLiteIsFlat: false)
    ) -> WorldItemLite {
        var item = WorldItemLite()
        item.groupID = groupID
        if let roomName {
            item.roomName = roomName
        }
        if let avatarURL {
            item.avatarURL = avatarURL
        }
        if let sortTimestampMicros {
            item.sortTimestamp = sortTimestampMicros
        }
        var readState = GroupReadState()
        readState.unreadMessageCount = unreadCount
        item.readState = readState
        var dmMembers = WorldItemLite.DmMembers()
        dmMembers.members = members.map(userID)
        item.dmMembers = dmMembers
        switch threading {
        case .threadedGroup:
            item.threadedGroup = WorldItemLite.ThreadedGroup()
        case .flatGroup:
            item.flatGroup = WorldItemLite.FlatGroup()
        case let .neither(isFlat):
            var groupLite = WorldItemLite.GroupLite()
            groupLite.isFlat = isFlat
            item.groupLite = groupLite
        case .none:
            break
        }
        return item
    }

    private func response(_ items: [WorldItemLite]) -> PaginatedWorldResponse {
        var response = PaginatedWorldResponse()
        response.worldItems = items
        return response
    }

    // MARK: - Identity, reusing ChannelEventMapping's namespace rule

    @Test func aSpaceItemGetsTheSpacePrefixedID() {
        let mapped = WorldMapping.map(response([item(groupID: spaceGroupID("s-1"))]))
        #expect(mapped.conversations.first?.id.rawValue == "space/s-1")
    }

    @Test func aDMItemGetsTheDMPrefixedID() {
        let mapped = WorldMapping.map(response([item(groupID: dmGroupID("d-1"))]))
        #expect(mapped.conversations.first?.id.rawValue == "dm/d-1")
    }

    // MARK: - Kind

    @Test func aSpaceGroupIDBecomesSpaceKind() {
        let mapped = WorldMapping.map(response([item(groupID: spaceGroupID("s-1"))]))
        #expect(mapped.conversations.first?.kind == .space)
    }

    @Test func aDMWithTwoOrFewerMembersIsADirectMessage() {
        let mapped = WorldMapping.map(response([
            item(groupID: dmGroupID("d-1"), members: ["u-1", "u-2"])
        ]))
        #expect(mapped.conversations.first?.kind == .directMessage)
    }

    @Test func aDMWithNoMembersListedIsStillADirectMessage() {
        let mapped = WorldMapping.map(response([item(groupID: dmGroupID("d-1"))]))
        #expect(mapped.conversations.first?.kind == .directMessage)
    }

    @Test func aDMWithMoreThanTwoMembersIsAGroupDirectMessage() {
        let mapped = WorldMapping.map(response([
            item(groupID: dmGroupID("d-1"), members: ["u-1", "u-2", "u-3"])
        ]))
        #expect(mapped.conversations.first?.kind == .groupDirectMessage)
    }

    // MARK: - Title: nil only when the wire never set the field

    /// An absent `room_name` - the field never set on the wire at all -
    /// becomes `nil`, per `Conversation.title`'s "derive from members" case.
    @Test func anAbsentRoomNameBecomesANilTitle() {
        let mapped = WorldMapping.map(response([item(groupID: dmGroupID("d-1"))]))
        #expect(mapped.conversations.first?.title == nil)
    }

    /// A `room_name` the wire explicitly set to `""` is a real, present title
    /// - kept as `""`, not collapsed into the "absent" case. This is the
    /// fixture `hasRoomName` exists to distinguish from the test above: both
    /// end up with an empty Swift string, but only one has the field set.
    @Test func aPresentButEmptyRoomNameIsKeptAsAnEmptyStringTitle() {
        let mapped = WorldMapping.map(response([item(groupID: dmGroupID("d-1"), roomName: "")]))
        #expect(mapped.conversations.first?.title == "")
    }

    @Test func aNonEmptyRoomNameIsKeptAsTheTitle() {
        let mapped = WorldMapping.map(response([
            item(groupID: spaceGroupID("s-1"), roomName: "Engineering")
        ]))
        #expect(mapped.conversations.first?.title == "Engineering")
    }

    // MARK: - Avatar

    @Test func anEmptyAvatarURLBecomesNil() {
        let mapped = WorldMapping.map(response([item(groupID: dmGroupID("d-1"), avatarURL: "")]))
        #expect(mapped.conversations.first?.avatarURL == nil)
    }

    @Test func aNonEmptyAvatarURLIsParsed() {
        let mapped = WorldMapping.map(response([
            item(groupID: dmGroupID("d-1"), avatarURL: "https://example.com/a.png")
        ]))
        #expect(mapped.conversations.first?.avatarURL?.absoluteString == "https://example.com/a.png")
    }

    // MARK: - Last activity: microseconds since the epoch

    @Test func sortTimestampBecomesLastActivityInMicroseconds() {
        let mapped = WorldMapping.map(response([
            item(groupID: dmGroupID("d-1"), sortTimestampMicros: 1_700_000_000_000_000)
        ]))
        #expect(mapped.conversations.first?.lastActivity == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func aMissingSortTimestampBecomesANilLastActivity() {
        let mapped = WorldMapping.map(response([item(groupID: dmGroupID("d-1"))]))
        #expect(mapped.conversations.first?.lastActivity == nil)
    }

    // MARK: - Unread count

    @Test func unreadMessageCountMapsThrough() {
        let mapped = WorldMapping.map(response([
            item(groupID: dmGroupID("d-1"), unreadCount: 7)
        ]))
        #expect(mapped.conversations.first?.unreadCount == 7)
    }

    // MARK: - Members

    @Test func dmMembersBecomeMemberIDs() {
        let mapped = WorldMapping.map(response([
            item(groupID: dmGroupID("d-1"), members: ["u-1", "u-2"])
        ]))
        #expect(mapped.conversations.first?.members == [Member.ID("u-1"), Member.ID("u-2")])
    }

    // MARK: - isThreaded

    @Test func aPresentThreadedGroupMakesItThreaded() {
        let mapped = WorldMapping.map(response([
            item(groupID: spaceGroupID("s-1"), threading: .threadedGroup)
        ]))
        #expect(mapped.conversations.first?.isThreaded == true)
    }

    @Test func aPresentFlatGroupMakesItNotThreaded() {
        let mapped = WorldMapping.map(response([
            item(groupID: spaceGroupID("s-1"), threading: .flatGroup)
        ]))
        #expect(mapped.conversations.first?.isThreaded == false)
    }

    @Test func neitherOneofFallsBackToGroupLiteIsFlatInverted() {
        let flat = WorldMapping.map(response([
            item(groupID: spaceGroupID("s-1"), threading: .neither(groupLiteIsFlat: true))
        ]))
        #expect(flat.conversations.first?.isThreaded == false)

        let threaded = WorldMapping.map(response([
            item(groupID: spaceGroupID("s-2"), threading: .neither(groupLiteIsFlat: false))
        ]))
        #expect(threaded.conversations.first?.isThreaded == true)
    }

    /// None of `threaded_group`, `flat_group` or `group_lite` present at all -
    /// `findings.md` §20.1 found `EXCLUDE_GROUP_LITE` can produce exactly this
    /// shape. "No information" must not read as "threaded".
    @Test func noThreadingInformationAtAllIsNotThreaded() {
        let mapped = WorldMapping.map(response([
            item(groupID: spaceGroupID("s-1"), threading: .none)
        ]))
        #expect(mapped.conversations.first?.isThreaded == false)
    }

    // MARK: - Nothing is silently dropped

    @Test func anItemWithNoGroupIDAtAllIsSkippedAndCounted() {
        let mapped = WorldMapping.map(response([WorldItemLite()]))
        #expect(mapped.conversations.isEmpty)
        #expect(mapped.skipped == 1)
    }

    @Test func anItemWithAnEmptySpaceIDIsSkippedAndCounted() {
        let mapped = WorldMapping.map(response([item(groupID: spaceGroupID(""))]))
        #expect(mapped.conversations.isEmpty)
        #expect(mapped.skipped == 1)
    }

    @Test func anItemWithAnEmptyDMIDIsSkippedAndCounted() {
        let mapped = WorldMapping.map(response([item(groupID: dmGroupID(""))]))
        #expect(mapped.conversations.isEmpty)
        #expect(mapped.skipped == 1)
    }

    @Test func validAndInvalidItemsAreBothAccountedForInOneRun() {
        let mapped = WorldMapping.map(response([
            item(groupID: spaceGroupID("s-1")),
            WorldItemLite(),
            item(groupID: dmGroupID("d-1")),
            item(groupID: spaceGroupID(""))
        ]))
        #expect(mapped.conversations.count == 2)
        #expect(mapped.skipped == 2)
    }

    @Test func anEmptyResponseProducesNoConversationsAndNoSkips() {
        let mapped = WorldMapping.map(response([]))
        #expect(mapped.conversations.isEmpty)
        #expect(mapped.skipped == 0)
    }
}
