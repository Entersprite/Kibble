import ChatKit
import Foundation
import Testing
@testable import LocalBridgeBackend

/// What counts as a change to a person's day (review finding 1): only what
/// draws, up to the horizon both answers cover.
struct CalendarDrawsTheSameTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ minutes: Double) -> Date {
        now.addingTimeInterval(minutes * 60)
    }

    /// Out of office to the end of the window, answered ten minutes apart:
    /// its end is the window's end, which moved, but nothing draws differently.
    @Test func anEntryRunningToTheWindowsEndDrawsTheSame() {
        let earlier = CalendarSchedule(
            entries: [.init(start: at(-10), end: at(710), kind: .outOfOffice, until: at(1500))],
            validUntil: at(710)
        )
        let later = CalendarSchedule(
            entries: [.init(start: at(0), end: at(720), kind: .outOfOffice, until: at(1500))],
            validUntil: at(720)
        )
        #expect(LocalBridgeBackend.drawsTheSame(earlier, later, now: now))
    }

    @Test func aNewMeetingInsideTheWindowDoesNot() {
        let free = CalendarSchedule(entries: [], validUntil: at(720))
        let meeting = CalendarSchedule(
            entries: [.init(start: at(60), end: at(90), kind: .inMeeting, until: at(90))],
            validUntil: at(720)
        )
        #expect(!LocalBridgeBackend.drawsTheSame(free, meeting, now: now))
        #expect(!LocalBridgeBackend.drawsTheSame(nil, free, now: now))
        #expect(LocalBridgeBackend.drawsTheSame(nil, nil, now: now))
    }
}
