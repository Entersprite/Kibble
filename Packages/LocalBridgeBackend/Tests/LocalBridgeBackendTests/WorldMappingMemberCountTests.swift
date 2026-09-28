import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `Conversation.memberCount`, from `segmented_membership_counts` (field 30).
///
/// The field was seen on every world item (`findings.md` §20.4, §37.1) and
/// its values have **never been decoded on the live account** `[Verify]`.
/// So these pin the rule the mapping applies, not a measured shape: sum the
/// segments that say JOINED, and say nothing when none does. The probe line
/// in `APIProbeReport+MembershipCounts.swift` is what checks the rule.
struct WorldMappingMemberCountTests {
    private func segment(
        _ count: Int32,
        type: MemberType? = .humanUser,
        state: MembershipState? = .memberJoined
    ) -> SegmentedMembershipCount {
        var segment = SegmentedMembershipCount()
        segment.membershipCount = count
        if let type {
            segment.memberType = type
        }
        if let state {
            segment.membershipState = state
        }
        return segment
    }

    private func memberCount(_ segments: [SegmentedMembershipCount]?) -> Int? {
        var item = WorldItemFixture.item(groupID: WorldItemFixture.spaceGroupID("s-1"), roomName: "Support")
        if let segments {
            var counts = SegmentedMembershipCounts()
            counts.value = segments
            item.segmentedMembershipCounts = counts
        }
        var response = PaginatedWorldResponse()
        response.worldItems = [item]
        return WorldMapping.map(response).conversations.first?.memberCount
    }

    @Test func joinedSegmentsAreSummedAcrossMemberTypes() {
        #expect(memberCount([segment(12), segment(3, type: .rosterMember)]) == 15)
    }

    /// An invitation is not membership. Chat's own header counts who is in.
    @Test func invitedSegmentsAreNotCounted() {
        #expect(memberCount([segment(12), segment(4, state: .memberInvited)]) == 12)
    }

    @Test func noFieldIsNoCount() {
        #expect(memberCount(nil) == nil)
    }

    /// A segment with no state is not assumed joined. proto2 also clears the
    /// presence bit for a state outside the vendored enum, so this is the path
    /// a new server value takes too.
    @Test func aSegmentWithNoStateIsNotCounted() {
        #expect(memberCount([segment(9, state: nil)]) == nil)
    }

    /// Zero joined members contradicts the account being in the
    /// conversation, so it is a rule this build has wrong, not a count.
    @Test func zeroIsUnknownRatherThanAnEmptyConversation() {
        #expect(memberCount([segment(0)]) == nil)
        #expect(memberCount([]) == nil)
    }
}
