import Foundation

/// RFC 3339 timestamps retaining the microsecond precision of read positions.
/// Existing millisecond timestamps keep their canonical three-digit encoding.
public enum RFC3339 {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFraction = Date.ISO8601FormatStyle()

    public static func date(from raw: String) -> Date? {
        (try? withFraction.parse(raw)) ?? (try? withoutFraction.parse(raw))
    }

    /// Uses six digits when needed and three when the value is an exact
    /// millisecond. Rounding can carry into the next second, including at epoch.
    public static func string(from date: Date) throws -> String {
        let timestamp = date.timeIntervalSince1970
        // RFC 3339 uses a four-digit year, from 0000 through 9999.
        let lowerBound = -62_167_219_200.0
        let upperBound = 253_402_300_800.0
        guard timestamp.isFinite, timestamp >= lowerBound, timestamp < upperBound else {
            throw EncodingError.invalidValue(date, .init(
                codingPath: [], debugDescription: "Invalid timestamp"
            ))
        }
        var seconds = timestamp.rounded(.down)
        var microseconds = Int(((timestamp - seconds) * 1_000_000).rounded())
        if microseconds == 1_000_000 {
            seconds += 1
            microseconds = 0
        }
        guard seconds < upperBound else {
            throw EncodingError.invalidValue(date, .init(
                codingPath: [], debugDescription: "Invalid timestamp"
            ))
        }
        let width = microseconds.isMultiple(of: 1000) ? 3 : 6
        let fraction = String(width == 3 ? microseconds / 1000 : microseconds)
        let padding = String(repeating: "0", count: max(0, width - fraction.count))
        let whole = withoutFraction.format(Date(timeIntervalSince1970: seconds))
        return whole.dropLast() + "." + padding + fraction + "Z"
    }
}
