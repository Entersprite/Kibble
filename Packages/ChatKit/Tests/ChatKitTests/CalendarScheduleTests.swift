import Foundation
import Testing
@testable import ChatKit

/// A person's day as the seam carries it (meeting indicator spec §2): which
/// entry holds a moment, and when the answer next changes.
struct CalendarScheduleTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ minutes: Double) -> Date {
        base.addingTimeInterval(minutes * 60)
    }

    /// Two back-to-back meetings sharing one "until", a gap, then focus time
    /// that runs past what is known.
    private var schedule: CalendarSchedule {
        CalendarSchedule(entries: [
            .init(start: at(0), end: at(30), kind: .inMeeting, until: at(60)),
            .init(start: at(30), end: at(60), kind: .inMeeting, until: at(60)),
            .init(start: at(90), end: at(120), kind: .focusTime, until: at(120))
        ], validUntil: at(100))
    }

    @Test func theEntryHoldingAMomentIsCurrentStartInclusiveEndExclusive() {
        #expect(schedule.current(at: at(-1)) == nil)
        #expect(schedule.current(at: at(0))?.end == at(30))
        #expect(schedule.current(at: at(30))?.start == at(30))
        #expect(schedule.current(at: at(75)) == nil)
    }

    @Test func nothingIsKnownFromValidUntilOn() {
        #expect(schedule.current(at: at(95))?.kind == .focusTime)
        #expect(schedule.current(at: at(100)) == nil)
    }

    @Test func boundariesAreEveryLaterStartEndAndValidUntilOnceInOrder() {
        #expect(schedule.boundaries(after: at(30)) == [at(60), at(90), at(100), at(120)])
        #expect(schedule.boundaries(after: at(200)).isEmpty)
    }

    /// A kind a newer backend sends survives this build, and draws nothing.
    @Test func anUnknownKindRoundTripsVerbatim() throws {
        let json = #"{"end":"2026-08-30T11:00:00.500Z","kind":"huddle","start":"2026-08-30T10:15:30.123Z"}"#
        let entry = try Wire.decode(CalendarSchedule.Entry.self, from: json)
        #expect(entry.kind == .unknown("huddle"))
        #expect(entry.until == nil)
        #expect(try Wire.json(entry) == json)
    }
}
