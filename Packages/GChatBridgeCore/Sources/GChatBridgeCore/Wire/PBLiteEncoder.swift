import Foundation
import SwiftProtobuf

/// Encoding is the strict direction of the codec: unlike decoding, which must
/// swallow everything Google sends, a message we cannot represent faithfully is
/// a bug on our side and is surfaced.
public enum PBLiteError: Error, Hashable, Sendable {
    /// A proto2 `required` field (possibly on a nested message) is unset.
    /// Mirrors upstream's `IsInitialized()` guard (pblite.py:152-153).
    case uninitializedMessage(String)
    /// pblite has no representation for this field kind. googlechat.proto
    /// contains no `map<>` and no `group` fields, so this cannot fire for the
    /// generated types; it exists so a future .proto that adds one fails loudly
    /// instead of encoding something the server will not understand.
    case unrepresentableField(messageName: String, fieldNumber: Int, kind: String)
    /// JSON text was not UTF-8. `JSONEncoder` cannot produce this, so it only
    /// exists because the conversion is failable and swallowing it would be worse.
    case nonUTF8JSON
}

/// Turns a `SwiftProtobuf.Message` into a pblite array.
///
/// The mechanism is SwiftProtobuf's own `Visitor`: `message.traverse(visitor:)`
/// calls back once per *set* field with that field's number, which is exactly
/// and only what positional encoding needs. That reproduces upstream's
/// `message.ListFields()` loop (pblite.py:157) without any reflection.
///
/// **Deliberate asymmetry with the decoder.** Upstream's decoder accepts a
/// trailing `{fieldNumber: value}` dictionary as an out-of-band carrier for high
/// field numbers (pblite.py:99-103), but its encoder has no counterpart and
/// always emits a plain positional list however long (pblite.py:172-175). That
/// asymmetry is preserved here on purpose: it is how the real client behaves, so
/// emitting the dictionary would be a novel, untested wire form. A message whose
/// highest set field is 100 therefore encodes as a 100-element array.
public enum PBLiteEncoder {
    /// - Returns: always `.array`; `.array([])` for a message with nothing set.
    public static func encode<M: SwiftProtobuf.Message>(_ message: M) throws -> PBLiteValue {
        guard message.isInitialized else {
            throw PBLiteError.uninitializedMessage(M.protoMessageName)
        }
        var sink = PBLiteFieldSink(messageName: M.protoMessageName)
        try message.traverse(visitor: &sink)
        return sink.positionalArray
    }

    /// The form that goes on the WebChannel: the pblite array as JSON bytes.
    public static func encodeJSON(_ message: some SwiftProtobuf.Message) throws -> Data {
        try encode(message).jsonData()
    }
}

/// Collects `(fieldNumber, value)` pairs during a traversal, then lays them out
/// positionally.
struct PBLiteFieldSink {
    let messageName: String
    private var fields: [Int: PBLiteValue] = [:]

    init(messageName: String) {
        self.messageName = messageName
    }

    /// Upstream's padding rule (pblite.py:172-175) stated as a single step: the
    /// array is exactly as long as the highest set field number, every unset slot
    /// in between is `null`, and a 1-based field number lands at index number-1.
    var positionalArray: PBLiteValue {
        guard let highest = fields.keys.max() else {
            return .array([])
        }
        var slots = [PBLiteValue](repeating: .null, count: highest)
        for (number, value) in fields {
            slots[number - 1] = value
        }
        return .array(slots)
    }

    private mutating func put(_ value: PBLiteValue, at fieldNumber: Int) {
        fields[fieldNumber] = value
    }

    private static func number(_ value: Int64) -> PBLiteValue {
        .number(.integer(value))
    }

    private static func number(_ value: UInt64) -> PBLiteValue {
        .number(.unsigned(value))
    }

    private static func number(_ value: Double) -> PBLiteValue {
        .number(.double(value))
    }

    private static func number(_ value: some Enum) -> PBLiteValue {
        .number(.integer(Int64(value.rawValue)))
    }

    private static func bytes(_ value: Data) -> PBLiteValue {
        .string(value.base64EncodedString())
    }

    private func unrepresentable(_ fieldNumber: Int, _ kind: String) -> PBLiteError {
        .unrepresentableField(messageName: messageName, fieldNumber: fieldNumber, kind: kind)
    }
}

// MARK: - SwiftProtobuf.Visitor

/// Only the singular 64-bit/bool/string/bytes/enum/message methods and the maps
/// lack a default implementation, but the *repeated* defaults must all be
/// overridden anyway: they iterate and call the singular visit with the same
/// field number, which for a positional codec would leave only the last element
/// standing. Every repeated method below is therefore written out, including the
/// ones that look redundant. The 32-bit and zigzag singular defaults are left
/// alone - widening to Int64/UInt64 is exactly right for a JSON number.
extension PBLiteFieldSink: SwiftProtobuf.Visitor {
    mutating func visitSingularDoubleField(value: Double, fieldNumber: Int) throws {
        put(Self.number(value), at: fieldNumber)
    }

    mutating func visitSingularInt64Field(value: Int64, fieldNumber: Int) throws {
        put(Self.number(value), at: fieldNumber)
    }

    mutating func visitSingularUInt64Field(value: UInt64, fieldNumber: Int) throws {
        put(Self.number(value), at: fieldNumber)
    }

    mutating func visitSingularBoolField(value: Bool, fieldNumber: Int) throws {
        put(.bool(value), at: fieldNumber)
    }

    mutating func visitSingularStringField(value: String, fieldNumber: Int) throws {
        put(.string(value), at: fieldNumber)
    }

    mutating func visitSingularBytesField(value: Data, fieldNumber: Int) throws {
        put(Self.bytes(value), at: fieldNumber)
    }

    mutating func visitSingularEnumField(value: some Enum, fieldNumber: Int) throws {
        put(Self.number(value), at: fieldNumber)
    }

    mutating func visitSingularMessageField(value: some SwiftProtobuf.Message, fieldNumber: Int) throws {
        try put(PBLiteEncoder.encode(value), at: fieldNumber)
    }

    mutating func visitRepeatedFloatField(value: [Float], fieldNumber: Int) throws {
        put(.array(value.map { Self.number(Double($0)) }), at: fieldNumber)
    }

    mutating func visitRepeatedDoubleField(value: [Double], fieldNumber: Int) throws {
        put(.array(value.map { Self.number($0) }), at: fieldNumber)
    }

    mutating func visitRepeatedInt32Field(value: [Int32], fieldNumber: Int) throws {
        put(.array(value.map { Self.number(Int64($0)) }), at: fieldNumber)
    }

    mutating func visitRepeatedInt64Field(value: [Int64], fieldNumber: Int) throws {
        put(.array(value.map { Self.number($0) }), at: fieldNumber)
    }

    mutating func visitRepeatedUInt32Field(value: [UInt32], fieldNumber: Int) throws {
        put(.array(value.map { Self.number(UInt64($0)) }), at: fieldNumber)
    }

    mutating func visitRepeatedUInt64Field(value: [UInt64], fieldNumber: Int) throws {
        put(.array(value.map { Self.number($0) }), at: fieldNumber)
    }

    mutating func visitRepeatedSInt32Field(value: [Int32], fieldNumber: Int) throws {
        try visitRepeatedInt32Field(value: value, fieldNumber: fieldNumber)
    }

    mutating func visitRepeatedSInt64Field(value: [Int64], fieldNumber: Int) throws {
        try visitRepeatedInt64Field(value: value, fieldNumber: fieldNumber)
    }

    mutating func visitRepeatedFixed32Field(value: [UInt32], fieldNumber: Int) throws {
        try visitRepeatedUInt32Field(value: value, fieldNumber: fieldNumber)
    }

    mutating func visitRepeatedFixed64Field(value: [UInt64], fieldNumber: Int) throws {
        try visitRepeatedUInt64Field(value: value, fieldNumber: fieldNumber)
    }

    mutating func visitRepeatedSFixed32Field(value: [Int32], fieldNumber: Int) throws {
        try visitRepeatedInt32Field(value: value, fieldNumber: fieldNumber)
    }

    mutating func visitRepeatedSFixed64Field(value: [Int64], fieldNumber: Int) throws {
        try visitRepeatedInt64Field(value: value, fieldNumber: fieldNumber)
    }

    mutating func visitRepeatedBoolField(value: [Bool], fieldNumber: Int) throws {
        put(.array(value.map { PBLiteValue.bool($0) }), at: fieldNumber)
    }

    mutating func visitRepeatedStringField(value: [String], fieldNumber: Int) throws {
        put(.array(value.map { PBLiteValue.string($0) }), at: fieldNumber)
    }

    mutating func visitRepeatedBytesField(value: [Data], fieldNumber: Int) throws {
        put(.array(value.map { Self.bytes($0) }), at: fieldNumber)
    }

    mutating func visitRepeatedEnumField(value: [some Enum], fieldNumber: Int) throws {
        put(.array(value.map { Self.number($0) }), at: fieldNumber)
    }

    mutating func visitRepeatedMessageField(value: [some SwiftProtobuf.Message], fieldNumber: Int) throws {
        try put(.array(value.map { try PBLiteEncoder.encode($0) }), at: fieldNumber)
    }

    mutating func visitSingularGroupField(value _: some SwiftProtobuf.Message, fieldNumber: Int) throws {
        throw unrepresentable(fieldNumber, "group")
    }

    mutating func visitRepeatedGroupField(value _: [some SwiftProtobuf.Message], fieldNumber: Int) throws {
        throw unrepresentable(fieldNumber, "repeated group")
    }

    mutating func visitMapField<KeyType, ValueType: MapValueType>(
        fieldType _: _ProtobufMap<KeyType, ValueType>.Type,
        value _: _ProtobufMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int
    ) throws {
        throw unrepresentable(fieldNumber, "map")
    }

    mutating func visitMapField<KeyType, ValueType>(
        fieldType _: _ProtobufEnumMap<KeyType, ValueType>.Type,
        value _: _ProtobufEnumMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int
    ) throws where ValueType.RawValue == Int {
        throw unrepresentable(fieldNumber, "enum map")
    }

    mutating func visitMapField<KeyType, ValueType>(
        fieldType _: _ProtobufMessageMap<KeyType, ValueType>.Type,
        value _: _ProtobufMessageMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int
    ) throws {
        throw unrepresentable(fieldNumber, "message map")
    }

    /// Upstream cannot hit this case at all: Python's `ListFields()` does not
    /// report unknown fields, so there is nothing to drop. Here a message that
    /// was parsed from binary protobuf can carry them, and pblite has no way to
    /// express a field whose number and wire type we do not know. Dropping is the
    /// only faithful option.
    mutating func visitUnknown(bytes _: Data) throws {}
}
