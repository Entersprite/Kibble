import Foundation

/// Parses the timestamp format Google Chat returns.
///
/// The API emits RFC 3339 with a variable-length fractional part — microseconds
/// (`...04.145372Z`), a single decimal (`...12.5Z`), or none at all
/// (`...00Z`). The ISO-8601 parsers accept exactly three fractional digits, so
/// the fraction is normalised to milliseconds first.
///
/// `Date.ISO8601FormatStyle` is used rather than `ISO8601DateFormatter` because
/// it is a `Sendable` value type, which Swift 6 strict concurrency requires of
/// shared statics.
enum RFC3339 {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFraction = Date.ISO8601FormatStyle()

    static func date(from raw: String) -> Date? {
        guard let dot = raw.firstIndex(of: ".") else {
            return try? withoutFraction.parse(raw)
        }
        let afterDot = raw.index(after: dot)
        let remainder = raw[afterDot...]
        let digits = remainder.prefix(while: \.isNumber)
        let milliseconds =
            digits.count >= 3
            ? String(digits.prefix(3))
            : String(digits).padding(toLength: 3, withPad: "0", startingAt: 0)
        let normalised = raw[..<afterDot] + milliseconds + remainder.dropFirst(digits.count)
        return try? withFraction.parse(String(normalised))
    }
}
