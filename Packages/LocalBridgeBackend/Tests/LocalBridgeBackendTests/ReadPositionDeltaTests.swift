import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `APIProbeReport+ReadPositions.swift`'s two pure halves: the histogram over
/// every world item (Change 1) and the probed conversation's own three
/// figures (Change 2). Both pure, so both are tested here against invented
/// `WorldItemLite`/timestamp values with no network and no account - the
/// same posture `ReadReceiptReportTests` already takes for its own arithmetic.
@Suite("APIProbeReport - read position deltas")
struct ReadPositionDeltaTests {
    // MARK: - Bucket edges

    /// `d = -1, 0, 1, 1_000, 1_001, 1_000_000, 1_000_001, 3_600_000_000,
    /// 3_600_000_001` - each lands in the stated bucket, and nowhere else
    /// (checked via full-struct equality, not just the one field).
    @Test func bucketEdgesLandInTheStatedBucket() {
        let group = WorldItemFixture.spaceGroupID("s-1")
        let base: Int64 = 1_000_000_000
        let cases: [(delta: Int64, expected: ReadPositionDeltaCounts)] = [
            (-1, ReadPositionDeltaCounts(covered: 1)),
            (0, ReadPositionDeltaCounts(equal: 1)),
            (1, ReadPositionDeltaCounts(upToOneMillisecond: 1)),
            (1000, ReadPositionDeltaCounts(upToOneMillisecond: 1)),
            (1001, ReadPositionDeltaCounts(upToOneSecond: 1)),
            (1_000_000, ReadPositionDeltaCounts(upToOneSecond: 1)),
            (1_000_001, ReadPositionDeltaCounts(upToOneHour: 1)),
            (3_600_000_000, ReadPositionDeltaCounts(upToOneHour: 1)),
            (3_600_000_001, ReadPositionDeltaCounts(older: 1))
        ]
        for testCase in cases {
            let item = WorldItemFixture.item(
                groupID: group,
                lastReadMicros: base,
                newestMessageMicros: base + testCase.delta
            )
            let deltas = APIProbeReport.readPositionDeltas([item])
            #expect(deltas.all == testCase.expected, "d=\(testCase.delta)")
        }
    }

    // MARK: - A missing presence bit

    /// A `WorldItemLite` whose typed `readState` leaves `lastReadTime` unset
    /// - `findings.md` §39.1's rule read the other way: absence counts as
    /// `notComparable`, never as `equal`.
    @Test func aMissingPresenceBitCountsAsNotComparableNeverEqual() {
        let group = WorldItemFixture.spaceGroupID("s-1")
        let item = WorldItemFixture.item(groupID: group, newestMessageMicros: 100)
        let deltas = APIProbeReport.readPositionDeltas([item])
        #expect(deltas.all == ReadPositionDeltaCounts(notComparable: 1))
    }

    // MARK: - The kind split

    /// One DM, one space and one Meet item (field 19 raw 10, the shape
    /// `WorldItemFixture.withRawGroupType` builds §37.4's way) - three
    /// different buckets, and the kind rows must sum to `all`.
    @Test func theKindSplitSumsToAllAcrossDMSpaceAndMeetChat() throws {
        let dmItem = WorldItemFixture.item(
            groupID: WorldItemFixture.dmGroupID("dm-1"),
            dmMembers: ["u1"],
            lastReadMicros: 100,
            newestMessageMicros: 50
        )
        let spaceItem = WorldItemFixture.item(
            groupID: WorldItemFixture.spaceGroupID("s-1"),
            roomName: "a space",
            lastReadMicros: 100,
            newestMessageMicros: 100
        )
        let meetBase = WorldItemFixture.item(
            groupID: WorldItemFixture.spaceGroupID("s-2"),
            lastReadMicros: 500,
            newestMessageMicros: 600
        )
        let meetItem = try WorldItemFixture.withRawGroupType(10, on: meetBase)

        let deltas = APIProbeReport.readPositionDeltas([dmItem, spaceItem, meetItem])

        #expect(deltas.byKind["directMessage"] == ReadPositionDeltaCounts(covered: 1))
        #expect(deltas.byKind["space"] == ReadPositionDeltaCounts(equal: 1))
        #expect(deltas.byKind["meetChat"] == ReadPositionDeltaCounts(upToOneMillisecond: 1))
        #expect(sumOfCounts(Array(deltas.byKind.values)) == deltas.all)
    }

    private func sumOfCounts(_ counts: [ReadPositionDeltaCounts]) -> ReadPositionDeltaCounts {
        counts.reduce(ReadPositionDeltaCounts()) { sum, next in
            ReadPositionDeltaCounts(
                covered: sum.covered + next.covered,
                equal: sum.equal + next.equal,
                upToOneMillisecond: sum.upToOneMillisecond + next.upToOneMillisecond,
                upToOneSecond: sum.upToOneSecond + next.upToOneSecond,
                upToOneHour: sum.upToOneHour + next.upToOneHour,
                older: sum.older + next.older,
                notComparable: sum.notComparable + next.notComparable
            )
        }
    }

    // MARK: - The smallest-positive list

    /// Capped at five, ascending - the values are supplied out of order and
    /// with more than five candidates so a passing test proves both the cap
    /// and the sort are real.
    @Test func smallestPositiveListIsCappedAtFiveAndAscending() {
        let group = WorldItemFixture.spaceGroupID("s-1")
        let deltasIn: [Int64] = [500, 10, 999_999, 1, 250_000, 2, 42]
        let items = deltasIn.map {
            WorldItemFixture.item(groupID: group, lastReadMicros: 1000, newestMessageMicros: 1000 + $0)
        }
        let lines = APIProbeReport.readPositionDeltaLines(APIProbeReport.readPositionDeltas(items))
        #expect(lines.contains("    smallest positive (≤1s): [1, 2, 10, 42, 500]"))
    }

    // MARK: - Rendering: all, then kinds in ascending token order

    @Test func linesPrintAllThenKindsInAscendingTokenOrder() {
        let spaceItem = WorldItemFixture.item(
            groupID: WorldItemFixture.spaceGroupID("s-1"),
            roomName: "a space",
            lastReadMicros: 100,
            newestMessageMicros: 100
        )
        let dmItem = WorldItemFixture.item(
            groupID: WorldItemFixture.dmGroupID("dm-1"),
            dmMembers: ["u1"],
            lastReadMicros: 100,
            newestMessageMicros: 50
        )
        // Supplied space-then-DM, so a passing "ascending token order" check
        // proves the rendering sorts rather than echoing encounter order -
        // "directMessage" sorts before "space".
        let lines = APIProbeReport.readPositionDeltaLines(APIProbeReport.readPositionDeltas([
            spaceItem,
            dmItem
        ]))
        let directMessageIndex = lines.firstIndex { $0.hasPrefix("    directMessage:") }
        let spaceIndex = lines.firstIndex { $0.hasPrefix("    space:") }
        #expect(directMessageIndex != nil)
        #expect(spaceIndex != nil)
        if let directMessageIndex, let spaceIndex {
            #expect(directMessageIndex < spaceIndex)
        }
    }

    // MARK: - The probed conversation's own figures

    @Test func probedConversationFiguresComputeBothDeltasAndAge() {
        let now = Date(timeIntervalSince1970: 12.3)
        let figures = APIProbeReport.probedConversationFigures(
            headTime: 100,
            lastReadTime: 40,
            newestMessageCreateTime: 0,
            now: now
        )
        let expectedNewestMinusReadPosition: Int64 = 60
        let expectedHeadMinusNewestMessage: Int64 = 100
        #expect(figures.newestMinusReadPosition == expectedNewestMinusReadPosition)
        #expect(figures.headMinusNewestMessage == expectedHeadMinusNewestMessage)
        #expect(APIProbeReport.probedConversationLine(figures) == "  probed conversation: "
            + "newest minus read position +60 µs; "
            + "field 29 minus newest list_topics message create_time +100 µs; "
            + "newest list_topics message age 12.3 s")
    }

    /// Each field is independently absent, and each absence prints `n/a` on
    /// its own figure rather than being guessed from the others.
    @Test func probedConversationLineReportsNAWhenEverythingIsMissing() {
        let figures = APIProbeReport.probedConversationFigures(
            headTime: nil,
            lastReadTime: nil,
            newestMessageCreateTime: nil,
            now: Date()
        )
        #expect(figures.newestMinusReadPosition == nil)
        #expect(figures.headMinusNewestMessage == nil)
        #expect(figures.newestMessageAgeSeconds == nil)
        #expect(APIProbeReport.probedConversationLine(figures) == "  probed conversation: "
            + "newest minus read position n/a; "
            + "field 29 minus newest list_topics message create_time n/a; "
            + "newest list_topics message age n/a")
    }

    /// `headTime` present but `newestMessageCreateTime` absent: the first
    /// figure still computes (it only needs `headTime`/`lastReadTime`) while
    /// the other two - which both need the message time - report `n/a`.
    @Test func probedConversationLineComputesOneFigureWhileTheOthersAreNA() {
        let figures = APIProbeReport.probedConversationFigures(
            headTime: 100,
            lastReadTime: 40,
            newestMessageCreateTime: nil,
            now: Date()
        )
        let expectedNewestMinusReadPosition: Int64 = 60
        #expect(figures.newestMinusReadPosition == expectedNewestMinusReadPosition)
        #expect(figures.headMinusNewestMessage == nil)
        #expect(figures.newestMessageAgeSeconds == nil)
    }

    // MARK: - Leak sentinel

    /// No rendered line contains an id or a name from the fixtures - the
    /// same posture the other probe sections' leak tests already take.
    @Test func noRenderedLineContainsAnIdOrNameFromTheFixtures() {
        let sentinelSpaceID = "SENTINEL-SPACE-ID-should-not-appear"
        let sentinelDMID = "SENTINEL-DM-ID-should-not-appear"
        let sentinelMemberID = "SENTINEL-MEMBER-ID-should-not-appear"
        let sentinelRoomName = "SENTINEL-ROOM-NAME-should-not-appear"
        let items = [
            WorldItemFixture.item(
                groupID: WorldItemFixture.dmGroupID(sentinelDMID),
                dmMembers: [sentinelMemberID],
                lastReadMicros: 100,
                newestMessageMicros: 50
            ),
            WorldItemFixture.item(
                groupID: WorldItemFixture.spaceGroupID(sentinelSpaceID),
                roomName: sentinelRoomName,
                lastReadMicros: 10,
                newestMessageMicros: 2_000_000
            )
        ]
        let rendered = APIProbeReport
            .readPositionDeltaLines(APIProbeReport.readPositionDeltas(items))
            .joined(separator: "\n")
        for sentinel in [sentinelSpaceID, sentinelDMID, sentinelMemberID, sentinelRoomName] {
            #expect(!rendered.contains(sentinel))
        }
    }
}
