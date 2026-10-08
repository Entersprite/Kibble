import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// A `GetAssistiveFeatures` calendar entry becomes a `CalendarSchedule`
/// (meeting indicator spec §3.2). Shaped like the owner's run (`findings.md`
/// §62.10); every value is invented.
struct CalendarMappingTests {
    private let arrivedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func time(_ seconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Unlabelled member 3, two meetings sharing one "until", a gap, focus
    /// time, busy, then out of office. Status member `k` sits at index `k - 1`.
    private static let day = #"""
    ["1",[[[null,"1"],[2,"u-1"],[[\#
    [[["1800000030"],["1800000600"]],[null,null,[null,["1800003600"]]],[null,null,["Area/City"]]],\#
    [[["1800000600"],["1800001200"]],[null,null,null,null,\#
    [null,["1800003600"],["1800003600"],["1800003600"],["1800003600"]]],[null,null,["Area/City"]]],\#
    [[["1800001200"],["1800003600"]],[null,null,null,null,\#
    [null,["1800003600"],["1800003600"],["1800003600"],["1800003600"]]],[null,null,["Area/City"]]],\#
    [[["1800003600"],["1800007200"]],[null,[]],[null,null,["Area/City"]]],\#
    [[["1800007200"],["1800010800"]],[null,null,null,null,null,null,[null,null,["1800010800"]]],\#
    [null,null,["Area/City"]]],\#
    [[["1800010800"],["1800014400"]],[null,null,null,null,null,[null,null,null,["1800014400"]]],\#
    [null,null,["Area/City"]]],\#
    [[["1800014400"],["1800043200"]],[null,null,null,[["1800090000"],null,["1800043200"]]],\#
    [null,null,["Area/City"]]]],\#
    ["1800043200"],[[1,540,1020]]]],\#
    [[5,"1"],[2,"u-2"]]]]
    """#

    private func entry(_ json: String, _ index: Int = 0) throws -> PeopleStackAnswer
        .Entry<PeopleStackCalendarStatus> {
        try #require(PeopleStackAnswer(Data(json.utf8))?.calendar[index])
    }

    private func schedule(_ json: String, _ index: Int = 0) throws -> CalendarSchedule? {
        let entry = try entry(json, index)
        return CalendarMapping.schedule(entry.payload, entryStatus: entry.status, arrivedAt: arrivedAt)
    }

    @Test func labelledIntervalsBecomeEntriesWithTheirUntil() throws {
        #expect(try schedule(Self.day) == CalendarSchedule(entries: [
            .init(
                start: time(1_800_000_600),
                end: time(1_800_001_200),
                kind: .inMeeting,
                until: time(1_800_003_600)
            ),
            .init(
                start: time(1_800_001_200),
                end: time(1_800_003_600),
                kind: .inMeeting,
                until: time(1_800_003_600)
            ),
            .init(
                start: time(1_800_007_200),
                end: time(1_800_010_800),
                kind: .focusTime,
                until: time(1_800_010_800)
            ),
            .init(
                start: time(1_800_010_800),
                end: time(1_800_014_400),
                kind: .busy,
                until: time(1_800_014_400)
            ),
            .init(
                start: time(1_800_014_400),
                end: time(1_800_043_200),
                kind: .outOfOffice,
                until: time(1_800_090_000)
            )
        ], validUntil: time(1_800_043_200)))
    }

    @Test func notFoundIsNoSchedule() throws {
        #expect(try schedule(Self.day, 1) == nil)
    }

    /// An entry the server marks other than ok draws nothing, even if it
    /// carries a day: the status decides, not the payload's presence.
    @Test func aNotFoundEntryWithADayIsStillNoSchedule() throws {
        let marked = #"["1",[[[5,"1"],[2,"u-1"],[[[[["1800000000"],["1800003600"]],"#
            + #"[null,null,null,null,[null,null,null,null,["1800003600"]]]]],["1800043200"]]]]]"#
        #expect(try schedule(marked) == nil)
    }

    /// A day with nothing labelled is an empty schedule, not "not found".
    @Test func aFreeDayIsAnEmptySchedule() throws {
        let free = #"["1",[[[null,"1"],[2,"u-1"],[[[[["1800000000"],["1800043200"]],"#
            + #"[null,[]]]],["1800043200"]]]]]"#
        #expect(try schedule(free) == CalendarSchedule(entries: [], validUntil: time(1_800_043_200)))
    }

    /// The client's own rule: a first interval starting within 59 s counts
    /// as now. At 60 s it does not.
    @Test func aFirstIntervalStartingWithin59SecondsStartsAtArrival() throws {
        func first(startingAt start: Int) -> String {
            #"["1",[[[null,"1"],[2,"u-1"],[[[[["\#(start)"],["1800003600"]],"#
                + #"[null,null,null,null,[null,null,null,null,["1800003600"]]]]],["1800043200"]]]]]"#
        }
        #expect(try schedule(first(startingAt: 1_800_000_059))?.entries.first?.start == arrivedAt)
        #expect(try schedule(first(startingAt: 1_800_000_060))?.entries.first?.start == time(1_800_000_060))
    }

    @Test func anIntervalWithoutAStartIsDropped() throws {
        let open = #"["1",[[[null,"1"],[2,"u-1"],[[[[null,["1800003600"]],"#
            + #"[null,null,null,null,[null,null,null,null,["1800003600"]]]]],["1800043200"]]]]]"#
        #expect(try schedule(open)?.entries.isEmpty == true)
    }
}
