import Foundation
import Testing
@testable import ChatKit

/// Google emits RFC 3339 timestamps with a variable number of fractional-second
/// digits, which is why this parser exists at all. Upstream it was only covered
/// incidentally, through Space decoding; the cases that actually broke are
/// pinned here directly.
///
/// Note this is NOT the bridge's timestamp format - the internal protocol uses
/// int64 microseconds. RFC 3339 is for seam JSON and fixture files.
@Suite("RFC 3339 parsing")
struct RFC3339Tests {
    @Test(
        "variable fractional-second digit counts all parse",
        arguments: [
            "2026-08-30T10:15:30Z",
            "2026-08-30T10:15:30.1Z",
            "2026-08-30T10:15:30.12Z",
            "2026-08-30T10:15:30.123Z",
            "2026-08-30T10:15:30.123456Z",
            "2026-08-30T10:15:30.123456789Z"
        ]
    )
    func parsesVariableFractions(_ raw: String) {
        #expect(RFC3339.date(from: raw) != nil, "failed to parse \(raw)")
    }

    @Test("the whole-second value is identical regardless of fractional digits")
    func fractionDoesNotShiftTheSecond() throws {
        let plain = try #require(RFC3339.date(from: "2026-08-30T10:15:30Z"))
        let fractional = try #require(RFC3339.date(from: "2026-08-30T10:15:30.999Z"))
        #expect(fractional.timeIntervalSince(plain) < 1.0)
        #expect(fractional >= plain)
    }

    @Test("malformed input returns nil rather than throwing")
    func rejectsMalformed() {
        #expect(RFC3339.date(from: "") == nil)
        #expect(RFC3339.date(from: "not a date") == nil)
        #expect(RFC3339.date(from: "2026-13-45T99:99:99Z") == nil)
    }
}
