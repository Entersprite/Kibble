import Foundation

// The primitives every hand-written `Codable` conformance in this package is
// built from.
//
// Hand-writing them is the rule here rather than the exception, because this
// JSON is a *protocol*: a bridge server frames `ChatEvent` values down the wire
// and `ChatCommand` values up it. Swift's synthesised enum encoding has an
// undocumented shape, no discriminator anyone can name, and nowhere to put a
// version — relying on it would make the protocol a compiler implementation
// detail that a toolchain upgrade is free to change. These helpers exist so
// that every conformance performs the same dance in the same way, once.

/// Reads and writes a value that is a bare JSON string, not an object wrapping
/// one. Used by the identifier types and by every open string enum.
enum WireString {
    static func decode(from decoder: any Decoder) throws -> String {
        try decoder.singleValueContainer().decode(String.self)
    }

    static func encode(_ value: String, to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Converts `Duration` to and from fractional seconds.
///
/// `Duration` already conforms to `Codable`, but it encodes as a two-element
/// array of the high and low halves of an attosecond count — a shape only Swift
/// can read, and one that says nothing to a reader of the wire. Fractional
/// seconds are what an HTTP `Retry-After` means anyway.
enum WireDuration {
    /// Beyond about 31 million years the conversion stops being meaningful, and
    /// clamping here keeps the `Int64` conversions below from trapping on a
    /// hostile or corrupt value.
    private static let limit: Double = 1e15
    private static let attosecondsPerSecond: Double = 1e18

    static func seconds(of duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / attosecondsPerSecond
    }

    static func duration(ofSeconds seconds: Double) -> Duration {
        guard seconds.isFinite else { return .zero }
        let clamped = min(max(seconds, -limit), limit)
        let whole = clamped.rounded(.towardZero)
        let fraction = ((clamped - whole) * attosecondsPerSecond).rounded()
        return Duration(
            secondsComponent: Int64(whole),
            attosecondsComponent: Int64(fraction)
        )
    }
}

/// The forward-compatibility escape hatch shared by `ChatEvent` and
/// `ChatCommand`: a frame whose discriminator this build has never heard of is
/// captured whole and written back out unchanged.
enum UnknownFrame {
    /// The discriminator key. Every frame in this protocol carries it.
    static let typeKey = "type"

    static func payload(from decoder: any Decoder) throws -> JSONValue {
        try JSONValue(from: decoder)
    }

    /// Writes the captured object verbatim, re-asserting the discriminator so a
    /// hand-built value still produces a well-formed frame.
    ///
    /// A payload that is not an object cannot be a frame, so it is nested under
    /// `payload` rather than silently dropped. Decoding never produces that
    /// shape; only constructing `.unknown` by hand can.
    static func encode(type: String, payload: JSONValue, to encoder: any Encoder) throws {
        var fields: [String: JSONValue] = if case let .object(object) = payload {
            object
        } else {
            ["payload": payload]
        }
        fields[typeKey] = .string(type)
        var container = encoder.singleValueContainer()
        try container.encode(JSONValue.object(fields))
    }
}

/// The error a hand-written encoder raises when it finds a case it has no
/// branch for.
///
/// It should be unreachable, and saying so out loud is the point: the enums in
/// this package encode through grouped helpers so that no single function ends
/// up too complex to read, which costs the compiler's exhaustiveness check.
/// This error is what replaces it — a case added without updating the encoder
/// fails loudly on the first attempt to send it, rather than silently putting
/// an object with no discriminator on the wire.
enum WireEncoding {
    static func unhandled(_ value: Any, path: [any CodingKey]) -> EncodingError {
        EncodingError.invalidValue(
            value,
            EncodingError.Context(
                codingPath: path,
                debugDescription: "No encoder branch for \(value)"
            )
        )
    }
}

// MARK: - Timestamps and durations in keyed containers

extension KeyedEncodingContainer {
    /// Timestamps go on the wire as RFC 3339 strings, never as a
    /// `TimeInterval`: a format only Apple's Foundation can read defeats the
    /// point of having a protocol.
    mutating func encodeWire(_ date: Date, forKey key: Key) throws {
        try encode(RFC3339.string(from: date), forKey: key)
    }

    /// `nil` is omitted rather than written as `null`, so absence has exactly
    /// one representation on the wire.
    mutating func encodeWireIfPresent(_ date: Date?, forKey key: Key) throws {
        guard let date else { return }
        try encodeWire(date, forKey: key)
    }

    mutating func encodeWireIfPresent(_ duration: Duration?, forKey key: Key) throws {
        guard let duration else { return }
        try encode(WireDuration.seconds(of: duration), forKey: key)
    }
}

extension KeyedDecodingContainer {
    func decodeWire(_: Date.Type, forKey key: Key) throws -> Date {
        let raw = try decode(String.self, forKey: key)
        return try wireDate(raw, path: codingPath + [key])
    }

    /// Accepts both an absent key and an explicit `null`, both meaning `nil`.
    func decodeWireIfPresent(_: Date.Type, forKey key: Key) throws -> Date? {
        guard let raw = try decodeIfPresent(String.self, forKey: key) else { return nil }
        return try wireDate(raw, path: codingPath + [key])
    }

    func decodeWireIfPresent(_: Duration.Type, forKey key: Key) throws -> Duration? {
        guard let seconds = try decodeIfPresent(Double.self, forKey: key) else { return nil }
        return WireDuration.duration(ofSeconds: seconds)
    }
}

private func wireDate(_ raw: String, path: [any CodingKey]) throws -> Date {
    guard let date = RFC3339.date(from: raw) else {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: path,
                debugDescription: "Not an RFC 3339 timestamp: \(raw)"
            )
        )
    }
    return date
}
