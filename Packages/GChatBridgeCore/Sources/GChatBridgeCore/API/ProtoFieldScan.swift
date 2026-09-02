import Foundation

/// One top-level field, described by number rather than by name.
public struct ProtoField: Sendable, Hashable {
    /// The field number off the wire. **Not** a generated case name: the proto
    /// this repo vendors is stale, and a number is the only thing that stays
    /// true across a regeneration.
    public let number: Int

    /// 0 varint, 1 fixed64, 2 length-delimited, 5 fixed32.
    public let wireType: Int

    /// Payload size in bytes, excluding the tag - and, for a length-delimited
    /// field (wire type 2), excluding its length-prefix varint too.
    public let byteCount: Int

    public init(number: Int, wireType: Int, byteCount: Int) {
        self.number = number
        self.wireType = wireType
        self.byteCount = byteCount
    }
}

/// A generic walk over binary protobuf, reporting what is there rather than
/// what was expected.
///
/// ## Why a typed decode is not enough
///
/// `findings.md` §12.1.1: the vendored proto's `EventType` stops at 50 and live
/// traffic carried 51, 64, 70 and 83; §3.6 saw `paginated_world` answer with
/// field 11, unnamed in the proto. A typed decode of either would report
/// success and silently discard the only interesting part. This is the binary
/// analogue of what `ChannelEvent` does for pblite: read the structure, name
/// nothing.
///
/// It reports **field numbers, wire types and sizes**. Never contents - a
/// response carries real messages.
public enum ProtoFieldScan {
    /// Walks the top level. `truncated` is true when the scan stopped early,
    /// which is a fact about the read and not necessarily about the data.
    ///
    /// Stopping rather than skipping is deliberate. §4 records the same failure
    /// in chunk framing: a wrong width does not fail at the mistake, it
    /// desynchronises and produces plausible-looking fields at wrong offsets one
    /// item later. A partial answer that admits it is partial is worth more than
    /// a complete-looking wrong one.
    public static func fields(in data: Data) -> (fields: [ProtoField], truncated: Bool) {
        var fields: [ProtoField] = []
        var index = data.startIndex

        while index < data.endIndex {
            guard let key = varint(data, &index) else { return (fields, true) }
            let number = Int(key >> 3)
            let wireType = Int(key & 7)
            guard number > 0 else { return (fields, true) }

            let start = index
            var payload: Range<Data.Index>?
            guard skipValue(wireType: wireType, in: data, index: &index, payload: &payload) else {
                // Wire type 3/4 (deprecated group markers) or anything else
                // that is not a wire type at all - `skipValue` cannot advance
                // past it, and guessing the width desynchronises everything
                // that follows.
                return (fields, true)
            }
            // A length-delimited field's byte count is its payload alone,
            // excluding the length-prefix varint `skipValue` already
            // consumed; every other wire type's count is simply how far
            // `skipValue` moved `index`.
            let byteCount = payload.map { data.distance(from: $0.lowerBound, to: $0.upperBound) }
                ?? data.distance(from: start, to: index)
            fields.append(ProtoField(number: number, wireType: wireType, byteCount: byteCount))
        }
        return (fields, false)
    }

    /// The raw bytes of every top-level occurrence of `number` as a
    /// length-delimited (wire type 2) field - every `world_items` (field 4)
    /// entry in a `PaginatedWorldResponse`, still encoded, so a caller can
    /// scan **inside** one without a typed decode.
    ///
    /// `findings.md` §20.4: the top-level scan never looked inside a
    /// `world_items` entry, so which `WorldItemLite` fields are actually
    /// populated has never been observed. This is what makes that scan
    /// possible without teaching this file anything about `WorldItemLite` -
    /// it stays what it already is, a generic walk over field numbers.
    ///
    /// A mismatched wire type, or anything the walk cannot read, simply ends
    /// the search - `fields(in:)`'s `truncated` flag already exists for a
    /// caller that needs to know the top level was incomplete; duplicating it
    /// here would be a second way to say the same thing.
    public static func payloads(ofField number: Int, in data: Data) -> [Data] {
        var results: [Data] = []
        var index = data.startIndex

        while index < data.endIndex {
            guard let key = varint(data, &index) else { return results }
            let fieldNumber = Int(key >> 3)
            let wireType = Int(key & 7)
            guard fieldNumber > 0 else { return results }

            var payload: Range<Data.Index>?
            guard skipValue(wireType: wireType, in: data, index: &index, payload: &payload) else {
                return results
            }
            if fieldNumber == number, let payload {
                results.append(data[payload])
            }
        }
        return results
    }

    /// Advances `index` past one field's value, given its `wireType`.
    ///
    /// `false` means the value could not be read - the walk stops there, the
    /// same rule `fields(in:)` and `payloads(ofField:in:)` both apply. For a
    /// length-delimited field (wire type 2), `payload` is set to its byte
    /// range; every other wire type leaves it `nil`.
    private static func skipValue(
        wireType: Int,
        in data: Data,
        index: inout Data.Index,
        payload: inout Range<Data.Index>?
    ) -> Bool {
        switch wireType {
        case 0:
            return varint(data, &index) != nil

        case 1, 5:
            let width = wireType == 1 ? 8 : 4
            guard data.distance(from: index, to: data.endIndex) >= width else { return false }
            index = data.index(index, offsetBy: width)
            return true

        case 2:
            guard let length = varint(data, &index),
                  let count = Int(exactly: length),
                  data.distance(from: index, to: data.endIndex) >= count
            else { return false }
            let start = index
            index = data.index(index, offsetBy: count)
            payload = start ..< index
            return true

        default:
            return false
        }
    }

    /// A base-128 varint. `nil` when the data ends mid-value or the value is
    /// wider than 64 bits.
    private static func varint(_ data: Data, _ index: inout Data.Index) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex {
            let byte = data[index]
            index = data.index(after: index)
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return value
            }
            shift += 7
            if shift >= 64 {
                return nil
            }
        }
        return nil
    }
}
