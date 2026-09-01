import Foundation

/// One top-level field, described by number rather than by name.
public struct ProtoField: Sendable, Hashable {
    /// The field number off the wire. **Not** a generated case name: the proto
    /// this repo vendors is stale, and a number is the only thing that stays
    /// true across a regeneration.
    public let number: Int

    /// 0 varint, 1 fixed64, 2 length-delimited, 5 fixed32.
    public let wireType: Int

    /// Payload size in bytes, excluding the tag.
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

            switch wireType {
            case 0:
                let start = index
                guard varint(data, &index) != nil else { return (fields, true) }
                fields.append(ProtoField(
                    number: number,
                    wireType: wireType,
                    byteCount: data.distance(from: start, to: index)
                ))

            case 1, 5:
                let width = wireType == 1 ? 8 : 4
                guard data.distance(from: index, to: data.endIndex) >= width else {
                    return (fields, true)
                }
                index = data.index(index, offsetBy: width)
                fields.append(ProtoField(number: number, wireType: wireType, byteCount: width))

            case 2:
                guard let length = varint(data, &index),
                      let count = Int(exactly: length),
                      data.distance(from: index, to: data.endIndex) >= count
                else {
                    return (fields, true)
                }
                index = data.index(index, offsetBy: count)
                fields.append(ProtoField(number: number, wireType: wireType, byteCount: count))

            default:
                // 3 and 4 are the deprecated group markers; anything else is not
                // a wire type at all. Either way the width of what follows is
                // unknown, and guessing it desynchronises the rest.
                return (fields, true)
            }
        }
        return (fields, false)
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
