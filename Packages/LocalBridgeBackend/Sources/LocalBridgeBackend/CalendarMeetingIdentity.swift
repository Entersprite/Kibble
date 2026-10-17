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

    func originalStart(timeZone: String) -> Date? {
        let timed = slot.count == 16
        guard let zone = TimeZone(identifier: timed ? "UTC" : timeZone) else { return nil }
        return Self.date(
            year: number(0 ..< 4), month: number(4 ..< 6), day: number(6 ..< 8),
            hour: timed ? number(9 ..< 11) : 0,
            minute: timed ? number(11 ..< 13) : 0,
            second: timed ? number(13 ..< 15) : 0, timeZone: zone
        )
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
