import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `WorldMapping+Kind.swift`: what sort of conversation an item is, and
/// whether it is threaded.
///
/// Field 19's mapping landed in session 23 with no tests, as agreed
/// experimentation, and the group-type-10 and group-chat reads followed it the
/// same way. Every earlier `WorldMapping` fixture leaves field 19 and
/// `name_users` unset, so the green suite covered only the fallback.
///
/// Each test here was checked by deleting or inverting the branch it names
/// and watching it fail (`CLAUDE.md`: a guard is not covered until its test
/// fails with the guard deleted). Where a DM fixture carries a member count,
/// the count is chosen so the fallback inference would give a *different*
/// answer - otherwise the test passes whether field 19 is read or not.
struct WorldMappingKindTests {
    private typealias Fixture = WorldItemFixture

    // MARK: - Field 19, when the generated enum can name the value

    /// Two members, which the fallback reads as a human `.directMessage`.
    @Test func aBotDMGroupTypeIsAnAppDirectMessage() {
        let item = Fixture.item(
            groupID: Fixture.dmGroupID("d-1"), dmMembers: ["u-1", "u-2"], groupType: .oneToOneBotDm
        )
        #expect(Fixture.mapped(item)?.kind == .appDirectMessage)
    }

    /// Value 6 is the **only** human-DM value on the real account - nine of
    /// nine (`findings.md` §37.4). Three members, which the fallback reads as a
    /// group DM.
    @Test func anImmutableMembershipHumanDMGroupTypeIsADirectMessage() {
        let item = Fixture.item(
            groupID: Fixture.dmGroupID("d-1"),
            dmMembers: ["u-1", "u-2", "u-3"],
            groupType: .immutableMembershipHumanDm
        )
        #expect(Fixture.mapped(item)?.kind == .directMessage)
    }

    /// Never observed on the real account; mapped by its name. Three members,
    /// for the same reason as the test above.
    @Test func aOneToOneHumanDMGroupTypeIsADirectMessage() {
        let item = Fixture.item(
            groupID: Fixture.dmGroupID("d-1"), dmMembers: ["u-1", "u-2", "u-3"], groupType: .oneToOneHumanDm
        )
        #expect(Fixture.mapped(item)?.kind == .directMessage)
    }

    /// Two members, which the fallback reads as a one-to-one DM.
    @Test func anImmutableMembershipGroupDMGroupTypeIsAGroupDirectMessage() {
        let item = Fixture.item(
            groupID: Fixture.dmGroupID("d-1"),
            dmMembers: ["u-1", "u-2"],
            groupType: .immutableMembershipGroupDm
        )
        #expect(Fixture.mapped(item)?.kind == .groupDirectMessage)
    }

    /// All three room values say `.space`. On a space identifier the fallback
    /// says `.space` too, so this pins the *answer*, not the branch: turning
    /// any of the three into "fall through" is behaviour-preserving on every
    /// shape a real item can take, and no realistic fixture can tell them
    /// apart. The DM tests above are what pin field 19 being read first.
    @Test func everyRoomGroupTypeIsASpace() {
        for groupType in [SharedAttributeCheckerGroupType.flatRoom, .threadedRoom, .postRoom] {
            let item = Fixture.item(
                groupID: Fixture.spaceGroupID("s-1"), roomName: "Design", groupType: groupType
            )
            #expect(Fixture.mapped(item)?.kind == .space, "\(groupType)")
        }
    }

    /// The presence bit is set and the value still says nothing, so the
    /// fallback decides. Three members, so a fallback answer is visible.
    @Test func anExplicitlyUnspecifiedGroupTypeFallsBackToTheInference() {
        let item = Fixture.item(
            groupID: Fixture.dmGroupID("d-1"),
            dmMembers: ["u-1", "u-2", "u-3"],
            groupType: .attributeCheckerGroupTypeUnspecified
        )
        #expect(item.hasAttributeCheckerGroupType)
        #expect(Fixture.mapped(item)?.kind == .groupDirectMessage)
    }

    // MARK: - Field 19, when it cannot (§37.4: values outside the proto2 enum)

    /// 187 of the real account's 220 conversations. The first expectation is
    /// the premise, not the subject: if a regenerated proto ever names 10,
    /// it goes red and forces a decision about this path.
    @Test func groupTypeTenOnASpaceIsAMeetChat() throws {
        let item = try Fixture.withRawGroupType(
            10, on: Fixture.item(groupID: Fixture.spaceGroupID("s-1"), roomName: "Weekly Sync - Sep 8")
        )
        #expect(!item.hasAttributeCheckerGroupType)
        #expect(Fixture.mapped(item)?.kind == .meetChat)
    }

    /// The path that found value 10: an unnamed number becomes a token keyed
    /// on the number, never an invented case name.
    @Test func anotherUnrecognisedGroupTypeOnASpaceIsUnknownKeyedOnItsNumber() throws {
        let item = try Fixture.withRawGroupType(
            12, on: Fixture.item(groupID: Fixture.spaceGroupID("s-1"), roomName: "Design")
        )
        #expect(Fixture.mapped(item)?.kind == .unknown("attributeCheckerGroupType12"))
    }

    /// Value 11, the real account's one DM outside the enum. It must stay
    /// `.directMessage` so `asAppDirectMessage` can still promote it - that is
    /// where the store's sixth app DM comes from (§37.4).
    @Test func anUnrecognisedGroupTypeOnADMStaysADirectMessage() throws {
        let item = try Fixture.withRawGroupType(
            11, on: Fixture.item(groupID: Fixture.dmGroupID("d-1"), dmMembers: ["u-1", "u-2"])
        )
        #expect(!item.hasAttributeCheckerGroupType)
        #expect(Fixture.mapped(item)?.kind == .directMessage)
    }

    // MARK: - Group chats: a space with no name of its own (§37.5)

    /// The measured shape of all six group chats: `flatRoom`, no
    /// `room_name`, `name_users` present, no `dm_members`. Field 19 alone says
    /// `.space`, so this fails if the group-chat check moves below it.
    @Test func aSpaceWithNoRoomNameAndNameUsersIsAGroupChat() {
        let item = Fixture.item(
            groupID: Fixture.spaceGroupID("s-1"), nameUsers: ["u-1", "u-2", "u-3"], groupType: .flatRoom
        )
        #expect(Fixture.mapped(item)?.kind == .groupDirectMessage)
    }

    /// Synthetic: no real item has both. It is the `room_name`-absent half of
    /// the test, reached on its own.
    @Test func aSpaceWithARoomNameIsNotAGroupChatEvenWithNameUsers() {
        let item = Fixture.item(
            groupID: Fixture.spaceGroupID("s-1"),
            roomName: "Design",
            nameUsers: ["u-1", "u-2"],
            groupType: .flatRoom
        )
        #expect(Fixture.mapped(item)?.kind == .space)
    }

    /// The `name_users`-present half, reached on its own.
    @Test func aSpaceWithNeitherRoomNameNorNameUsersIsNotAGroupChat() {
        let item = Fixture.item(groupID: Fixture.spaceGroupID("s-1"), groupType: .flatRoom)
        #expect(Fixture.mapped(item)?.kind == .space)
    }

    /// Synthetic: the §37.5 cross-tab found no DM carrying `name_users`. It is
    /// the namespace guard, reached on its own.
    @Test func aDMCarryingNameUsersIsNotReclassifiedAsAGroupChat() {
        let item = Fixture.item(
            groupID: Fixture.dmGroupID("d-1"),
            dmMembers: ["u-1", "u-2"],
            nameUsers: ["u-1", "u-2"],
            groupType: .immutableMembershipHumanDm
        )
        #expect(Fixture.mapped(item)?.kind == .directMessage)
    }

    // MARK: - Threading: field 19 before the structural ladder

    /// Synthetic, as all three threading tests are: a real item would not
    /// carry a contradicting marker. The contradiction is the only way to show
    /// which one wins.
    @Test func aThreadedRoomGroupTypeBeatsAFlatGroupMarker() {
        let item = Fixture.item(
            groupID: Fixture.spaceGroupID("s-1"), roomName: "Design", groupType: .threadedRoom,
            flatGroup: true
        )
        #expect(Fixture.mapped(item)?.isThreaded == true)
    }

    @Test func aFlatRoomGroupTypeBeatsAThreadedGroupMarker() {
        let item = Fixture.item(
            groupID: Fixture.spaceGroupID("s-1"), roomName: "Design", groupType: .flatRoom,
            threadedGroup: true
        )
        #expect(Fixture.mapped(item)?.isThreaded == false)
    }

    /// `postRoom` says nothing about threading, so the ladder decides.
    @Test func aGroupTypeThatSaysNothingAboutThreadingDefersToTheLadder() {
        let item = Fixture.item(
            groupID: Fixture.spaceGroupID("s-1"), roomName: "Design", groupType: .postRoom,
            threadedGroup: true
        )
        #expect(Fixture.mapped(item)?.isThreaded == true)
    }
}
