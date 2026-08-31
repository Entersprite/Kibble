import Foundation

/// A whole JSON document as a value.
///
/// It exists for one job: when a frame arrives whose discriminator this build
/// has never heard of, the frame is captured here and written back out
/// unchanged. Without that, deploying a newer bridge server would brick every
/// older client, which is the failure mode this seam is shaped to avoid.
///
/// Numbers are `Double`, which is what JSON says a number is. Note the
/// consequence: an integer larger than 2^53 does not survive verbatim. Chat's
/// own identifiers and microsecond timestamps are `int64` on the internal
/// protocol, so a future unknown frame carrying one as a bare JSON number
/// would lose precision here. Nothing in the current protocol does — every
/// identifier crossing this seam is a string — but a `case integer(Int64)`
/// would be the fix if one ever appears.
public indirect enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Not representable as JSON"
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try Self.encode(number: value, into: &container)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    /// An integral value is written as an integer so that `{"n":1}` survives a
    /// round trip looking like itself rather than becoming `{"n":1.0}` or, past
    /// 1e17, `{"n":1e+17}`. Beyond 2^53 the `Double` is no longer exact, so
    /// there is nothing to be gained by pretending.
    private static func encode(
        number: Double,
        into container: inout SingleValueEncodingContainer
    ) throws {
        let exactIntegerLimit = 9_007_199_254_740_992.0
        if number.rounded() == number, abs(number) <= exactIntegerLimit {
            try container.encode(Int64(number))
        } else {
            try container.encode(number)
        }
    }
}
