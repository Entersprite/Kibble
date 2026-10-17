import Foundation
import Testing
@testable import LocalBridgeBackend

struct CalendarMeetingIdentityTests {
    @Test func calendarInstancesUseTheirOriginalSlotAndPreserveUnderscoresInTheBase() throws {
        let timed = try #require(CalendarMeetingIdentity.parse("base_with_underscores_20261012T090000Z"))
        #expect(timed.base == "base_with_underscores")
        let original = try #require(timed.originalStart(timeZone: "America/New_York"))
        #expect(original == Date(timeIntervalSince1970: 1_791_795_600))
        let date = try #require(CalendarMeetingIdentity.parse("base_20261012"))
        #expect(date.originalStart(timeZone: "UTC") == Date(timeIntervalSince1970: 1_791_763_200))
        #expect(date.originalStart(timeZone: "not-a-time-zone") == nil)
    }

    @Test func dateOnlySlotStartsAtTheFirstInstantOfADayWhoseMidnightIsSkipped() throws {
        // America/Santiago moved its clocks from 00:00 to 01:00 on 8 September 2024.
        let identity = try #require(CalendarMeetingIdentity.parse("base_20240908"))
        #expect(identity
            .originalStart(timeZone: "America/Santiago") == Date(timeIntervalSince1970: 1_725_768_000))
    }

    @Test func dateOnlySlotWithoutATimeZoneFloatsInTheGivenZone() throws {
        let identity = try #require(CalendarMeetingIdentity.parse("base_20261012"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(identity
            .originalStart(timeZone: "", floatingZone: tokyo) == Date(timeIntervalSince1970: 1_791_730_800))
        #expect(identity.originalStart(timeZone: "not-a-time-zone", floatingZone: tokyo) == nil)
    }

    @Test(arguments: [
        "ordinary-id", "base_with_underscores", "_20261012", "base_R20261012",
        "base_R20261012T090000", "base_20261012T090000", "base_20261012t090000Z",
        "base_20261012T090000z", "base_20261012T09000xZ", "base_20261012T090000Z_extra"
    ])
    func ordinaryMalformedAndRangeIDsRemainUngrouped(_ identifier: String) {
        #expect(CalendarMeetingIdentity.parse(identifier) == nil)
    }

    @Test(arguments: ["base_20260230", "base_20269999T999999Z", "base_20261012T250000Z"])
    func numericButInvalidCalendarSlotsAreRefused(_ identifier: String) throws {
        let identity = try #require(CalendarMeetingIdentity.parse(identifier))
        #expect(identity.originalStart(timeZone: "UTC") == nil)
    }
}
