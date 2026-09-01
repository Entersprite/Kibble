import Foundation
import Testing
@testable import GChatBridgeCore

@Suite("ProtoFieldScan")
struct ProtoFieldScanTests {
    @Test func aVarintFieldIsReported() {
        // Field 1, wire type 0, value 3.
        let scan = ProtoFieldScan.fields(in: Data([0x08, 0x03]))
        #expect(scan.truncated == false)
        #expect(scan.fields == [ProtoField(number: 1, wireType: 0, byteCount: 1)])
    }

    @Test func aLengthDelimitedFieldReportsItsPayloadSize() {
        // Field 2, wire type 2, length 2, "hi".
        let scan = ProtoFieldScan.fields(in: Data([0x12, 0x02, 0x68, 0x69]))
        #expect(scan.fields == [ProtoField(number: 2, wireType: 2, byteCount: 2)])
    }

    @Test func fixed64AndFixed32AreBothWalked() {
        // Field 3 wire type 1 (8 bytes), then field 4 wire type 5 (4 bytes).
        var data = Data([0x19]) + Data(repeating: 0, count: 8)
        data += Data([0x25]) + Data(repeating: 0, count: 4)
        let scan = ProtoFieldScan.fields(in: data)
        #expect(scan.truncated == false)
        #expect(scan.fields == [
            ProtoField(number: 3, wireType: 1, byteCount: 8),
            ProtoField(number: 4, wireType: 5, byteCount: 4)
        ])
    }

    @Test func severalFieldsAreReportedInOrder() {
        let scan = ProtoFieldScan.fields(in: Data([0x08, 0x03, 0x12, 0x02, 0x68, 0x69]))
        #expect(scan.fields.map(\.number) == [1, 2])
    }

    /// §3.6 saw `paginated_world` answer with field 11, which the vendored proto
    /// cannot name. A scanner that only reported fields it recognised would have
    /// reported nothing at all for that response.
    @Test func aFieldNumberTheProtoCannotNameIsStillReported() {
        // Field 11, wire type 0, value 21 - exactly what §3.6 recorded.
        let scan = ProtoFieldScan.fields(in: Data([0x58, 0x15]))
        #expect(scan.fields == [ProtoField(number: 11, wireType: 0, byteCount: 1)])
    }

    @Test func aTwoByteTagIsDecoded() {
        // Field 100, wire type 2 -> key 802 -> 0xA2 0x06, length 0.
        let scan = ProtoFieldScan.fields(in: Data([0xA2, 0x06, 0x00]))
        #expect(scan.fields == [ProtoField(number: 100, wireType: 2, byteCount: 0)])
    }

    /// The §4 lesson, in a different codec: a wrong width does not fail at the
    /// mistake, it desynchronises everything after it. Stopping is the only safe
    /// move, and saying so is what stops a partial read looking complete.
    ///
    /// The trailing bytes matter: a fixture that happens to be followed by an
    /// invalid tag would still read `truncated == true` even if the scanner
    /// wrongly kept going, because that next tag independently fails. Field
    /// 1 varint 3; tag 0x13 = field 2 wire type 3 (deprecated group start,
    /// unreadable); then 0x08 0x05, which a scanner that wrongly continued
    /// would read as a second, valid-looking field.
    @Test func anUnknownWireTypeStopsTheScanAndSaysSo() {
        let scan = ProtoFieldScan.fields(in: Data([0x08, 0x03, 0x13, 0x08, 0x05]))
        #expect(scan.truncated == true)
        #expect(scan.fields == [ProtoField(number: 1, wireType: 0, byteCount: 1)])
    }

    @Test func aLengthRunningPastTheEndIsTruncatedNotGuessed() {
        // Field 2, wire type 2, claims 9 bytes, supplies 2.
        let scan = ProtoFieldScan.fields(in: Data([0x12, 0x09, 0x68, 0x69]))
        #expect(scan.truncated == true)
        #expect(scan.fields.isEmpty)
    }

    @Test func aTagCutOffMidVarintIsTruncated() {
        #expect(ProtoFieldScan.fields(in: Data([0xA2])).truncated == true)
    }

    @Test func fieldNumberZeroIsInvalidAndStopsTheScan() {
        #expect(ProtoFieldScan.fields(in: Data([0x00, 0x00])).truncated == true)
    }

    @Test func anEmptyBodyScansCleanlyAsNothing() {
        let scan = ProtoFieldScan.fields(in: Data())
        #expect(scan.truncated == false)
        #expect(scan.fields.isEmpty)
    }

    /// A tag varint ten bytes long, every byte carrying the continuation bit,
    /// exceeds the 64-bit `shift >= 64` guard. An off-by-one here would still
    /// pass every other test in this file, since none of them drive a varint
    /// anywhere near that wide.
    @Test func aTagVarintWiderThanSixtyFourBitsIsTruncated() {
        let scan = ProtoFieldScan.fields(in: Data(repeating: 0x80, count: 10))
        #expect(scan.truncated == true)
        #expect(scan.fields.isEmpty)
    }

    /// Real captures arrive as slices of a larger buffer, not fresh `Data`
    /// starting at index 0 - this is the same bug class as §4's chunk framing.
    /// The implementation uses `distance(from:to:)` and `index(_:offsetBy:)`
    /// rather than integer arithmetic on indices specifically so this holds;
    /// a slice must scan identically to the equivalent standalone `Data`.
    @Test func aSliceWithANonZeroStartIndexScansIdenticallyToFreshData() {
        let sliced = Data([0xFF, 0xFF, 0x08, 0x03])[2...]
        let unsliced = Data([0x08, 0x03])
        #expect(ProtoFieldScan.fields(in: sliced) == ProtoFieldScan.fields(in: unsliced))
    }

    /// A length-delimited field whose declared length varint is near
    /// `UInt64.max` must report truncated rather than trapping when the
    /// scanner tries to work with it as an `Int`. Covers the `Int(exactly:)`
    /// path in the wire-type-2 branch.
    @Test func aHugeDeclaredLengthIsTruncatedRatherThanTrapping() {
        // Field 2, wire type 2, then a length varint encoding UInt64.max.
        let scan = ProtoFieldScan.fields(in: Data([0x12]) + Data(repeating: 0xFF, count: 9) + Data([0x01]))
        #expect(scan.truncated == true)
        #expect(scan.fields.isEmpty)
    }
}
