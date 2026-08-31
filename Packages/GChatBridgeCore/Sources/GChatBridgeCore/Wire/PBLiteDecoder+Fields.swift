import Foundation
import SwiftProtobuf

// PBLiteFieldSource's SwiftProtobuf.Decoder conformance, split out of
// PBLiteDecoder.swift only because it is 60 near-identical methods and both
// halves stay readable apart. The coercion rules it leans on are in
// PBLiteScalar.swift.

/// Mechanical, and deliberately exhaustive: `SwiftProtobuf.Decoder` supplies no
/// default implementations, so a type this protocol does not cover is a compile
/// error here rather than a silent wrong answer at runtime.
extension PBLiteFieldSource: SwiftProtobuf.Decoder {
    /// Permissive, like everything else here: a `oneof` that receives a second
    /// value keeps the last one instead of failing the message.
    mutating func handleConflictingOneOf() throws {}

    mutating func nextFieldNumber() throws -> Int? {
        advance()
    }

    mutating func decodeSingularFloatField(value: inout Float) throws {
        single(&value)
    }

    mutating func decodeSingularFloatField(value: inout Float?) throws {
        single(&value)
    }

    mutating func decodeRepeatedFloatField(value: inout [Float]) throws {
        repeated(&value)
    }

    mutating func decodeSingularDoubleField(value: inout Double) throws {
        single(&value)
    }

    mutating func decodeSingularDoubleField(value: inout Double?) throws {
        single(&value)
    }

    mutating func decodeRepeatedDoubleField(value: inout [Double]) throws {
        repeated(&value)
    }

    mutating func decodeSingularInt32Field(value: inout Int32) throws {
        single(&value)
    }

    mutating func decodeSingularInt32Field(value: inout Int32?) throws {
        single(&value)
    }

    mutating func decodeRepeatedInt32Field(value: inout [Int32]) throws {
        repeated(&value)
    }

    mutating func decodeSingularInt64Field(value: inout Int64) throws {
        single(&value)
    }

    mutating func decodeSingularInt64Field(value: inout Int64?) throws {
        single(&value)
    }

    mutating func decodeRepeatedInt64Field(value: inout [Int64]) throws {
        repeated(&value)
    }

    mutating func decodeSingularUInt32Field(value: inout UInt32) throws {
        single(&value)
    }

    mutating func decodeSingularUInt32Field(value: inout UInt32?) throws {
        single(&value)
    }

    mutating func decodeRepeatedUInt32Field(value: inout [UInt32]) throws {
        repeated(&value)
    }

    mutating func decodeSingularUInt64Field(value: inout UInt64) throws {
        single(&value)
    }

    mutating func decodeSingularUInt64Field(value: inout UInt64?) throws {
        single(&value)
    }

    mutating func decodeRepeatedUInt64Field(value: inout [UInt64]) throws {
        repeated(&value)
    }

    mutating func decodeSingularSInt32Field(value: inout Int32) throws {
        single(&value)
    }

    mutating func decodeSingularSInt32Field(value: inout Int32?) throws {
        single(&value)
    }

    mutating func decodeRepeatedSInt32Field(value: inout [Int32]) throws {
        repeated(&value)
    }

    mutating func decodeSingularSInt64Field(value: inout Int64) throws {
        single(&value)
    }

    mutating func decodeSingularSInt64Field(value: inout Int64?) throws {
        single(&value)
    }

    mutating func decodeRepeatedSInt64Field(value: inout [Int64]) throws {
        repeated(&value)
    }

    mutating func decodeSingularFixed32Field(value: inout UInt32) throws {
        single(&value)
    }

    mutating func decodeSingularFixed32Field(value: inout UInt32?) throws {
        single(&value)
    }

    mutating func decodeRepeatedFixed32Field(value: inout [UInt32]) throws {
        repeated(&value)
    }

    mutating func decodeSingularFixed64Field(value: inout UInt64) throws {
        single(&value)
    }

    mutating func decodeSingularFixed64Field(value: inout UInt64?) throws {
        single(&value)
    }

    mutating func decodeRepeatedFixed64Field(value: inout [UInt64]) throws {
        repeated(&value)
    }

    mutating func decodeSingularSFixed32Field(value: inout Int32) throws {
        single(&value)
    }

    mutating func decodeSingularSFixed32Field(value: inout Int32?) throws {
        single(&value)
    }

    mutating func decodeRepeatedSFixed32Field(value: inout [Int32]) throws {
        repeated(&value)
    }

    mutating func decodeSingularSFixed64Field(value: inout Int64) throws {
        single(&value)
    }

    mutating func decodeSingularSFixed64Field(value: inout Int64?) throws {
        single(&value)
    }

    mutating func decodeRepeatedSFixed64Field(value: inout [Int64]) throws {
        repeated(&value)
    }

    mutating func decodeSingularBoolField(value: inout Bool) throws {
        single(&value)
    }

    mutating func decodeSingularBoolField(value: inout Bool?) throws {
        single(&value)
    }

    mutating func decodeRepeatedBoolField(value: inout [Bool]) throws {
        repeated(&value)
    }

    mutating func decodeSingularStringField(value: inout String) throws {
        single(&value)
    }

    mutating func decodeSingularStringField(value: inout String?) throws {
        single(&value)
    }

    mutating func decodeRepeatedStringField(value: inout [String]) throws {
        repeated(&value)
    }

    mutating func decodeSingularBytesField(value: inout Data) throws {
        single(&value)
    }

    mutating func decodeSingularBytesField(value: inout Data?) throws {
        single(&value)
    }

    mutating func decodeRepeatedBytesField(value: inout [Data]) throws {
        repeated(&value)
    }

    mutating func decodeSingularEnumField<E: Enum>(value: inout E) throws where E.RawValue == Int {
        guard let decoded: E = nextEnum() else {
            return
        }
        value = decoded
    }

    mutating func decodeSingularEnumField<E: Enum>(value: inout E?) throws where E.RawValue == Int {
        guard let decoded: E = nextEnum() else {
            return
        }
        value = decoded
    }

    mutating func decodeRepeatedEnumField<E: Enum>(value: inout [E]) throws where E.RawValue == Int {
        guard case let .array(items) = take() else {
            value = []
            record(.malformedRepeated)
            return
        }
        var decoded: [E] = []
        for item in items {
            guard let raw = Int(pblite: item), let one = E(rawValue: raw) else {
                value = []
                record(.malformedRepeated)
                return
            }
            decoded.append(one)
        }
        value += decoded
    }

    /// Rule 8: a nested message recurses with a nested array. Merging into an
    /// existing value rather than replacing it mirrors upstream's
    /// `decode(getattr(message, field.name), value)`.
    mutating func decodeSingularMessageField<M: SwiftProtobuf.Message>(value: inout M?) throws {
        let raw = take()
        guard raw.arrayValue != nil else {
            record(.malformedScalar)
            return
        }
        var nested = value ?? M()
        decodeNested(&nested, from: raw)
        value = nested
    }

    /// A non-array element still appends an empty message, which is what
    /// upstream's `decode(field.add(), value)` leaves behind when the value is
    /// not a list.
    mutating func decodeRepeatedMessageField<M: SwiftProtobuf.Message>(value: inout [M]) throws {
        guard case let .array(items) = take() else {
            value = []
            record(.malformedRepeated)
            return
        }
        var decoded: [M] = []
        for item in items {
            var one = M()
            decodeNested(&one, from: item)
            decoded.append(one)
        }
        value += decoded
    }

    mutating func decodeSingularGroupField(value _: inout (some SwiftProtobuf.Message)?) throws {
        unrepresentable()
    }

    mutating func decodeRepeatedGroupField(value _: inout [some SwiftProtobuf.Message]) throws {
        unrepresentable()
    }

    mutating func decodeMapField<KeyType, ValueType: MapValueType>(
        fieldType _: _ProtobufMap<KeyType, ValueType>.Type,
        value _: inout _ProtobufMap<KeyType, ValueType>.BaseType
    ) throws {
        unrepresentable()
    }

    mutating func decodeMapField<KeyType, ValueType>(
        fieldType _: _ProtobufEnumMap<KeyType, ValueType>.Type,
        value _: inout _ProtobufEnumMap<KeyType, ValueType>.BaseType
    ) throws where ValueType.RawValue == Int {
        unrepresentable()
    }

    mutating func decodeMapField<KeyType, ValueType>(
        fieldType _: _ProtobufMessageMap<KeyType, ValueType>.Type,
        value _: inout _ProtobufMessageMap<KeyType, ValueType>.BaseType
    ) throws {
        unrepresentable()
    }

    mutating func decodeExtensionField(
        values _: inout ExtensionFieldValueSet,
        messageType _: any SwiftProtobuf.Message.Type,
        fieldNumber _: Int
    ) throws {
        unrepresentable()
    }
}
