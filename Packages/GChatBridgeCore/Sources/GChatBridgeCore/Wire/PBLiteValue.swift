import Foundation

/// A JSON number, kept in the representation it arrived in.
///
/// A bare `Double` would be lossy, and lossy in exactly the place that matters:
/// pblite carries 64-bit group/user ids and microsecond timestamps, and anything
/// past 2^53 does not survive a round trip through a binary64.
///
/// Equality and hashing are *numeric*, not representational, because JSON itself
/// draws no distinction between `1`, `1.0` and an unsigned `1`. Without that, a
/// tree that round-tripped through `JSONEncoder`/`JSONDecoder` would compare
/// unequal to the tree it started as, purely because the serialiser collapsed
/// `Double(1.0)` to the token `1`.
public enum PBLiteNumber: Hashable, Sendable {
    case integer(Int64)
    case unsigned(UInt64)
    case double(Double)
}

public extension PBLiteNumber {
    /// Representation-independent form, used only for `==` and `hash(into:)`.
    private enum Canonical: Hashable {
        case signed(Int64)
        case unsigned(UInt64)
        case real(Double)
    }

    private var canonical: Canonical {
        switch self {
        case let .integer(value):
            return .signed(value)
        case let .unsigned(value):
            return Int64(exactly: value).map(Canonical.signed) ?? .unsigned(value)
        case let .double(value):
            if let signed = Int64(exactly: value) {
                return .signed(signed)
            }
            if let unsigned = UInt64(exactly: value) {
                return .unsigned(unsigned)
            }
            return .real(value)
        }
    }

    static func == (lhs: PBLiteNumber, rhs: PBLiteNumber) -> Bool {
        lhs.canonical == rhs.canonical
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(canonical)
    }

    /// pblite's int64 coercion (`int(value)` upstream), widened to every integer
    /// width. A non-integral number is rejected rather than truncated; see the
    /// deviation note on `PBLiteDecoder`.
    func exactInteger<T: FixedWidthInteger>() -> T? {
        switch self {
        case let .integer(value):
            T(exactly: value)
        case let .unsigned(value):
            T(exactly: value)
        case let .double(value):
            T(exactly: value)
        }
    }

    var doubleValue: Double {
        switch self {
        case let .integer(value):
            Double(value)
        case let .unsigned(value):
            Double(value)
        case let .double(value):
            value
        }
    }
}

/// One node of a pblite tree: JSON's value domain and nothing else.
///
/// pblite is a protobuf message rendered as a JSON array in which *array
/// position is the field number*. That makes the payload a plain JSON tree with
/// no schema attached, which is why this type exists separately from the
/// protobuf layer: `PBLiteEncoder`/`PBLiteDecoder` convert between a
/// `SwiftProtobuf.Message` and one of these, and `Codable` moves it to and from
/// the bytes on the wire.
public enum PBLiteValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(PBLiteNumber)
    case string(String)
    case array([PBLiteValue])
    case object([String: PBLiteValue])
}

// MARK: - Accessors

public extension PBLiteValue {
    var isNull: Bool {
        if case .null = self {
            return true
        }
        return false
    }

    var arrayValue: [PBLiteValue]? {
        guard case let .array(items) = self else {
            return nil
        }
        return items
    }

    var objectValue: [String: PBLiteValue]? {
        guard case let .object(entries) = self else {
            return nil
        }
        return entries
    }

    var stringValue: String? {
        guard case let .string(text) = self else {
            return nil
        }
        return text
    }

    /// The value as an `Int`, or `nil` if it is not exactly one.
    ///
    /// Exactly, in both directions: a fractional double is not an integer, and
    /// a value outside `Int`'s range is not one either. `Int(exactly:)` rather
    /// than a truncating conversion because the caller that wants this is
    /// building a request parameter out of it — the channel's `aid` — and an
    /// `AID` quietly rounded is a client that replays or skips events without
    /// ever reporting a failure.
    ///
    /// A whole `Double` counts. JSON draws no distinction between `1` and
    /// `1.0`, so refusing the second would make the answer depend on which
    /// serialiser produced the tree.
    var intValue: Int? {
        guard case let .number(number) = self else {
            return nil
        }
        switch number {
        case let .integer(value): return Int(exactly: value)
        case let .unsigned(value): return Int(exactly: value)
        case let .double(value): return Int(exactly: value)
        }
    }

    /// True for the three values upstream considers "trivial" and therefore not
    /// worth reporting when they land on an unknown field number
    /// (`value not in [[], "", 0]`, pblite.py:114).
    var isTrivial: Bool {
        switch self {
        case let .array(items):
            items.isEmpty
        case let .string(text):
            text.isEmpty
        case let .number(number):
            number == .integer(0)
        default:
            false
        }
    }
}

// MARK: - Literals

extension PBLiteValue: ExpressibleByNilLiteral {
    public init(nilLiteral _: ()) {
        self = .null
    }
}

extension PBLiteValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension PBLiteValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) {
        self = .number(.integer(value))
    }
}

extension PBLiteValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .number(.double(value))
    }
}

extension PBLiteValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension PBLiteValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: PBLiteValue...) {
        self = .array(elements)
    }
}

extension PBLiteValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, PBLiteValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Codable

extension PBLiteValue: Codable {
    /// Order matters. `Bool` is tried before the integers so `true` does not
    /// become `1`, and `Int64`/`UInt64` before `Double` so a large id keeps every
    /// digit instead of being rounded into a binary64.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .number(.integer(value))
        } else if let value = try? container.decode(UInt64.self) {
            self = .number(.unsigned(value))
        } else if let value = try? container.decode(Double.self) {
            self = .number(.double(value))
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([PBLiteValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: PBLiteValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "not a JSON value"
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
        case let .number(.integer(value)):
            try container.encode(value)
        case let .number(.unsigned(value)):
            try container.encode(value)
        case let .number(.double(value)):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

// MARK: - JSON

public extension PBLiteValue {
    /// Parses a pblite tree from JSON bytes.
    ///
    /// `Codable` rather than `JSONSerialization` deliberately:
    /// `JSONSerialization` hands back `Any` (`NSNumber`, `NSNull`), so telling an
    /// integer from a double means interrogating an Objective-C bridged type, and
    /// `NSNumber`/`NSNull` are exactly the sort of Darwin-shaped Foundation that
    /// GChatBridgeCore must not depend on to keep its Linux build honest.
    /// `JSONEncoder` also writes an `Int64` as an integer token, so large ids
    /// survive a round trip that a `Double` pipeline would silently corrupt.
    init(json data: Data) throws {
        self = try JSONDecoder().decode(PBLiteValue.self, from: data)
    }

    /// Serialises the tree to JSON bytes.
    ///
    /// `sortedKeys` only affects the trailing high-field-number dictionary, which
    /// this encoder never emits (see `PBLiteEncoder`); it exists so a decoded
    /// tree containing one can be re-serialised deterministically in tests.
    func jsonData(sortedKeys: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        if sortedKeys {
            encoder.outputFormatting = .sortedKeys
        }
        return try encoder.encode(self)
    }

    func jsonString(sortedKeys: Bool = false) throws -> String {
        let data = try jsonData(sortedKeys: sortedKeys)
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw PBLiteError.nonUTF8JSON
        }
        return text
    }
}
