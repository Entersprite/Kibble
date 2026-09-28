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

    /// Writes the format above back out, always with exactly three fractional
    /// digits: `2026-08-30T10:15:30.123Z`.
    ///
    /// Milliseconds are a deliberate choice, not the input's precision echoed
    /// back. A fixed width keeps the encoder's output canonical — one `Date`
    /// has one representation — which is what makes golden-file comparison and
    /// byte-identical round-tripping possible at all. The cost is that
    /// sub-millisecond precision does not survive a round trip, **and that
    /// cost is real**: a read position must name its message to the
    /// microsecond, or a mark can land before the message it names and
    /// Google keeps the conversation unread (`findings.md` §42.1, where the
    /// store's millisecond dates did exactly that). No read position passes
    /// through here in-process today - the store keeps message dates as REAL
    /// seconds (`StoredDate`) - but a `ChatEvent` or `ChatCommand.markRead`
    /// frame sent to a server would, so this format has to carry microseconds
    /// before any server work: a wire and golden-file change, deliberately not
    /// made yet.
    static func string(from date: Date) -> String {
        withFraction.format(date)
    }
}
