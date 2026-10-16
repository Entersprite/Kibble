import Foundation

/// Read positions need microseconds even when older message frames use millisecond dates.
enum ReadPositionDate {
    private static let whole = Date.ISO8601FormatStyle()

    static func string(_ date: Date) -> String {
        let micros = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
        let seconds = micros >= 0 ? micros / 1_000_000 : (micros - 999_999) / 1_000_000
        let fraction = micros - seconds * 1_000_000
        let base = whole.format(Date(timeIntervalSince1970: Double(seconds)))
        return String(base.dropLast()) + String(format: ".%06lldZ", fraction)
    }

    static func date(_ string: String) -> Date? {
        guard let dot = string.firstIndex(of: ".") else { return try? whole.parse(string) }
        let remainder = string[string.index(after: dot)...]
        let digits = remainder.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 6,
              let fraction = Int(digits),
              let base = try? whole.parse(String(string[..<dot]) + remainder.dropFirst(digits.count))
        else { return nil }
        return Date(timeIntervalSince1970: base.timeIntervalSince1970
            + Double(fraction) / pow(10, Double(digits.count)))
    }
}
