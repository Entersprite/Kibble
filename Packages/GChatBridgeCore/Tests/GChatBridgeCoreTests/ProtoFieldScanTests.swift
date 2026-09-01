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
    @Test func anUnknownWireTypeStopsTheScanAndSaysSo() {
        // Field 1 varint 3, then field 2 wire type 3 (deprecated group start).
        let scan = ProtoFieldScan.fields(in: Data([0x08, 0x03, 0x13, 0x00]))
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
}
