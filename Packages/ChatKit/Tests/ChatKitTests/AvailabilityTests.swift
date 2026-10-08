import Foundation
import Testing
@testable import ChatKit

/// Your own availability on the wire (set-your-status spec §2).
struct AvailabilityTests {
    @Test func eachCaseMatchesItsGolden() throws {
        try expectWireStable(Availability.away, golden: "availability-away")
        try expectWireStable(
            Availability.doNotDisturb(until: Fixture.readAt),
            golden: "availability-doNotDisturb"
        )
    }

    @Test func automaticHasNoPayload() throws {
        #expect(try Wire.json(Availability.automatic) == #"{"type":"automatic"}"#)
    }

    /// A newer backend's state survives this build.
    @Test func anUnknownTypeRoundTrips() throws {
        let decoded = try Wire.decode(Availability.self, from: #"{"type":"inFocus"}"#)
        #expect(decoded == .unknown("inFocus"))
        #expect(try Wire.json(decoded) == #"{"type":"inFocus"}"#)
    }
}
