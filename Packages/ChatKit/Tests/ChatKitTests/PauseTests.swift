import Foundation
import Testing
@testable import ChatKit

struct PauseTests {
    private let at = Date(timeIntervalSince1970: 1_790_000_000)

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    @Test func aPauseIsActiveUntilItsDateAndNotAtIt() {
        let until = Date(timeIntervalSince1970: 1_790_003_600)
        #expect(Pause.until(until).isActive(at: at))
        #expect(!Pause.until(until).isActive(at: until))
        #expect(Pause.untilResumed.isActive(at: at))
        #expect(!Pause.off.isActive(at: at))
    }

    /// Decision 2: a pause this build cannot show or resume must not
    /// swallow notifications.
    @Test func anUnrecognisedPauseIsNotActive() {
        #expect(!Pause.unknown(type: "untilEvent", payload: .object([:])).isActive(at: at))
    }

    @Test func oneHourIsAnHourFromNow() {
        let now = Date(timeIntervalSince1970: 1_790_377_200) // 2026-09-25 23:00Z
        #expect(PauseDuration.oneHour.pause(from: now, calendar: calendar("UTC"))
            == .until(Date(timeIntervalSince1970: 1_790_380_800)))
    }

    /// Decision 3: "tomorrow" is the next calendar day, even just after midnight.
    @Test func untilTomorrowIsNineTheNextCalendarDay() {
        let lateEvening = Date(timeIntervalSince1970: 1_790_377_200) // 2026-09-25 23:00Z
        #expect(PauseDuration.untilTomorrow.pause(from: lateEvening, calendar: calendar("UTC"))
            == .until(Date(timeIntervalSince1970: 1_790_413_200))) // 2026-09-26 09:00Z
        let afterMidnight = Date(timeIntervalSince1970: 1_790_388_000) // 2026-09-26 02:00Z
        #expect(PauseDuration.untilTomorrow.pause(from: afterMidnight, calendar: calendar("UTC"))
            == .until(Date(timeIntervalSince1970: 1_790_499_600))) // 2026-09-27 09:00Z
    }

    /// Wall-clock 09:00 across the end of daylight saving (New York,
    /// 2026-11-01), not "now plus eleven hours".
    @Test func untilTomorrowKeepsNineOClockAcrossADaylightSavingChange() {
        let evening = Date(timeIntervalSince1970: 1_793_498_400) // 2026-10-31 22:00 EDT
        #expect(PauseDuration.untilTomorrow.pause(from: evening, calendar: calendar("America/New_York"))
            == .until(Date(timeIntervalSince1970: 1_793_541_600))) // 2026-11-01 09:00 EST
    }

    @Test func untilResumedHasNoDate() {
        #expect(PauseDuration.untilResumed.pause(from: at, calendar: calendar("UTC")) == .untilResumed)
    }

    @Test func settingAPauseReplacesItsRecordAndResumingKeepsOne() {
        var settings = NotificationSettings()
        #expect(settings.pause == .off)
        settings.setPause(.untilResumed, at: at, by: "t")
        settings.setPause(.off, at: at, by: "t")
        #expect(settings.pause == .off)
        #expect(settings.records.count == 1)
    }
}
