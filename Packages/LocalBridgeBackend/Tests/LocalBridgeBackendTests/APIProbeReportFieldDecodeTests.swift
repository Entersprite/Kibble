import ChatKit
import Foundation
import GChatBridgeCore
import SwiftProtobuf
import Testing
@testable import LocalBridgeBackend

/// The value-safe decode of `UserStatus` fields 9 and 10 (`findings.md`
/// §46.3): timestamps relative to the run, small numbers as themselves, text
/// as its length only. Pinned because the byte strings may be meeting titles.
struct APIProbeReportFieldDecodeTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func micros(_ offset: TimeInterval) -> UInt64 {
        UInt64((now.timeIntervalSince1970 + offset) * 1_000_000)
    }

    private func varint(_ value: UInt64) -> Data {
        var value = value
        var bytes = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 {
                byte |= 0x80
            }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    private func field(_ number: Int, varint value: UInt64) -> Data {
        varint(UInt64(number << 3)) + varint(value)
    }

    private func field(_ number: Int, bytes: Data) -> Data {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
    }

    /// Field 9 as §46.2 saw it: an event-like record, a state, and a string.
    private var meeting: Data {
        let event = field(2, bytes: Data("Standup with Ada".utf8))
            + field(3, varint: micros(-14 * 60))
            + field(4, varint: micros(46 * 60))
            + field(5, varint: 1)
        return field(
            9,
            bytes: field(1, bytes: event) + field(2, varint: 1) + field(3, bytes: Data("abc".utf8))
        )
    }

    @Test func timesAreRelativeAndTextIsALength() {
        let decoded = APIProbeReport.decodedShape(of: meeting, depth: 3, now: now)
        #expect(decoded == "9{1{2:text(16),3@now-14m,4@now+46m,5=1},2=1,3:text(3)}")
        #expect(!decoded.contains("Standup"))
        #expect(!decoded.contains("abc"))
    }

    /// Field 10 as §46.2 saw it: two nested timestamps, here hours and days
    /// away, which is what an out-of-office range would look like.
    @Test func longerRangesUseLargerUnits() {
        let range = field(
            10,
            bytes: field(1, bytes: field(1, varint: micros(-3 * 3600)))
                + field(2, bytes: field(1, varint: micros(4 * 86400)))
        )
        #expect(APIProbeReport.decodedShape(of: range, depth: 3, now: now) == "10{1{1@now-3h},2{1@now+4d}}")
    }

    /// A varint that is neither small nor a plausible time stays opaque: it
    /// could be an id.
    @Test func anOpaqueNumberIsNotPrinted() {
        #expect(APIProbeReport.decodedShape(of: field(7, varint: 123_456), depth: 3, now: now) == "7:varint")
    }

    @Test func theDecodedLinesLabelEntriesWithoutIds() throws {
        var mine = UserStatus()
        mine.userID.id = "me"
        var theirs = UserStatus()
        theirs.userID.id = "SENTINEL-ID"
        let theirBytes: Data = try theirs.serializedBytes()
        theirs = try UserStatus(serializedBytes: theirBytes + meeting)
        let lines = APIProbeReport.decodedStatusLines([mine, theirs], selfUserID: "me", now: now)
        #expect(lines == [
            "  decoded unnamed fields (times relative to now, text as length only):",
            "    entry 1: 9{1{2:text(16),3@now-14m,4@now+46m,5=1},2=1,3:text(3)}"
        ])
        #expect(!lines.joined().contains("SENTINEL"))
    }
}
