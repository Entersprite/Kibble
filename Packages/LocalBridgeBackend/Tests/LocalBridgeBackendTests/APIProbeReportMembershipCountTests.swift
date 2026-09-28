import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The probe's `membership counts` section (`findings.md` §43). Pinned
/// because it is what decides whether `WorldMapping.memberCount(for:)`'s
/// rule is right, and a probe line that misreports reads as a verdict.
struct APIProbeReportMembershipCountTests {
    private func segment(
        _ count: Int32,
        type: MemberType,
        state: MembershipState
    ) -> SegmentedMembershipCount {
        var segment = SegmentedMembershipCount()
        segment.membershipCount = count
        segment.memberType = type
        segment.membershipState = state
        return segment
    }

    private func item(
        _ groupID: GroupId,
        dmMembers: [String] = [],
        segments: [SegmentedMembershipCount]
    ) -> WorldItemLite {
        var item = WorldItemFixture.item(groupID: groupID, dmMembers: dmMembers)
        var counts = SegmentedMembershipCounts()
        counts.value = segments
        item.segmentedMembershipCounts = counts
        return item
    }

    private func lines(_ items: [WorldItemLite]) -> [String] {
        var response = PaginatedWorldResponse()
        response.worldItems = items
        let conversations = WorldMapping.map(response).conversations
        return APIProbeReport.membershipCountLines(items, conversations: conversations)
    }

    @Test func aDMWhoseCountMatchesItsListReportsZeroDelta() {
        let dm = item(
            WorldItemFixture.dmGroupID("d-1"),
            dmMembers: ["u-1", "u-2"],
            segments: [segment(2, type: .humanUser, state: .memberJoined)]
        )
        let report = lines([dm])
        #expect(report.contains("  present: 1 of 1"))
        #expect(report.contains("  segment shapes, raw bytes (type/state: segments) [1/2: 1]"))
        #expect(report.contains("    directMessage: [0: 1], no count: 0"))
    }

    /// The typed accessor cannot see a state outside the vendored enum; the
    /// byte walk can. This is the case the walk exists for.
    @Test func aStateTheEnumDoesNotKnowStillShowsInTheRawShapes() throws {
        // count 7, type 1, state 9 - hand-encoded, because the generated enum
        // cannot hold 9.
        let unknownState = try SegmentedMembershipCount(serializedBytes: Data([
            0x08,
            0x07,
            0x10,
            0x01,
            0x18,
            0x09
        ]))
        #expect(!unknownState.hasMembershipState)
        let space = item(WorldItemFixture.spaceGroupID("s-1"), segments: [unknownState])

        let report = lines([space])
        #expect(report.contains("  segment shapes, raw bytes (type/state: segments) [1/9: 1]"))
        #expect(report.contains("  memberCount derived: 0 of 1"))
        #expect(report.contains("    space: [], no count: 1"))
    }

    @Test func noFieldStopsAfterThePresenceLine() {
        let bare = WorldItemFixture.item(groupID: WorldItemFixture.spaceGroupID("s-1"))
        #expect(lines([bare]) == [
            "membership counts (field 30, segmented_membership_counts, findings 43):",
            "  present: 0 of 1"
        ])
    }
}
