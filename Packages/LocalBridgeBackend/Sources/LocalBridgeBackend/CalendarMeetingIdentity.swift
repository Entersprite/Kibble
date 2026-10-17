import Foundation

/// Calendar's source-defined instance syntax (findings.md §70.8–70.9).
/// Ordinary IDs and range identifiers stay ungrouped. Dates must also be valid,
/// rather than only satisfying the web parser's numeric character grammar.
struct CalendarMeetingIdentity {
    let base: String
    private let slot: [UInt8]

    static func parse(_ value: String) -> Self? {
        guard value.utf8.count <= 512, let split = value.lastIndex(of: "_"),
              split != value.startIndex else { return nil }
        let base = String(value[..<split])
        guard !base.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        let slot = Array(value[value.index(after: split)...].utf8)
        guard slot.count == 8 || slot.count == 16 else { return nil }
        for index in slot.indices {
            if index == 8 {
                guard slot[index] == 84 else { return nil }
            } else if index == 15 {
                guard slot[index] == 90 else { return nil }
            } else {
                guard (48 ... 57).contains(slot[index]) else { return nil }
            }
        }
        return Self(base: base, slot: slot)
    }

    func originalStart(timeZone: String, floatingZone: TimeZone = .current) -> Date? {
        guard slot.count == 16 else {
            guard let zone = Self.zone(timeZone, floating: floatingZone) else { return nil }
            return Self.day(
                year: number(0 ..< 4),
                month: number(4 ..< 6),
                day: number(6 ..< 8),
                timeZone: zone
            )
        }
        return Self.date(
            year: number(0 ..< 4), month: number(4 ..< 6), day: number(6 ..< 8),
            hour: number(9 ..< 11), minute: number(11 ..< 13), second: number(13 ..< 15),
            timeZone: .gmt
        )
    }

    /// A date-only value with no zone floats with the reader, so the caller's
    /// zone orders it. An unrecognized zone name is still refused.
    static func zone(_ identifier: String, floating: TimeZone) -> TimeZone? {
        identifier.isEmpty ? floating : TimeZone(identifier: identifier)
    }

    /// The first instant of a calendar day. A clock change can skip midnight,
    /// so the day is validated at noon and its start taken from the calendar.
    static func day(year: Int, month: Int, day: Int, timeZone: TimeZone) -> Date? {
        guard let noon = date(year: year, month: month, day: day, hour: 12, timeZone: timeZone) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.startOfDay(for: noon)
    }

    static func date(
        year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0,
        timeZone: TimeZone
    ) -> Date? {
        guard (1 ... 9999).contains(year), (1 ... 12).contains(month), (1 ... 31).contains(day),
              (0 ... 23).contains(hour), (0 ... 59).contains(minute), (0 ... 59).contains(second) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        )
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard roundTrip == components else { return nil }
        return date
    }

    private func number(_ range: Range<Int>) -> Int {
        slot[range].reduce(0) { $0 * 10 + Int($1 - 48) }
    }
}
