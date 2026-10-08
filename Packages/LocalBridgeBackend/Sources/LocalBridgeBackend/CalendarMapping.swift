import ChatKit
import Foundation
import GChatBridgeCore

/// One person's PeopleStack calendar status as a `CalendarSchedule`
/// (meeting indicator spec §3.2, `findings.md` §62.6 and §62.10).
///
/// Everything Google-specific stops here: the status members, which field
/// holds each kind's "until", and the client's 59-second rule.
enum CalendarMapping {
    /// The status oneof's members worth drawing. 2 and 3 have no label in the
    /// web client and are dropped.
    static let kinds: [Int: CalendarSchedule.Kind] = [
        4: .outOfOffice, 5: .inMeeting, 6: .busy, 7: .focusTime
    ]

    /// Which field of each member's message the web client reads as its
    /// "until" (`[Verify]` beyond meetings, §62.6).
    static let untilField = [4: 1, 5: 5, 6: 4, 7: 3]

    /// The web client counts a first interval starting this soon as now.
    static let startGrace: TimeInterval = 59

    /// `nil` for "not found" (an entry status other than ok) or no payload.
    static func schedule(
        _ status: PeopleStackCalendarStatus?,
        entryStatus: Int?,
        arrivedAt: Date
    ) -> CalendarSchedule? {
        guard entryStatus == nil || entryStatus == 0, let status else { return nil }
        var entries: [CalendarSchedule.Entry] = []
        for (index, interval) in status.intervals.enumerated() {
            guard let member = interval.member, let kind = kinds[member],
                  var start = interval.start, let end = interval.end
            else { continue }
            if index == 0, start > arrivedAt, start.timeIntervalSince(arrivedAt) <= startGrace {
                start = arrivedAt
            }
            let until = untilField[member].flatMap { interval.times[$0] }
            entries.append(CalendarSchedule.Entry(start: start, end: end, kind: kind, until: until))
        }
        return CalendarSchedule(entries: entries, validUntil: status.validUntil)
    }
}
