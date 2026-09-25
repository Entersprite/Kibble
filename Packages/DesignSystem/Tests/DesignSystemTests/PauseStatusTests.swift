import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// The status line under "Pause notifications", and the menu bar's. Times
/// are stubbed: what is under test is which sentence, not Foundation's
/// formatting.
struct PauseStatusTests {
    private let now = Date(timeIntervalSince1970: 1_790_377_200) // 2026-09-25 23:00Z

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func status(_ pause: Pause) -> String? {
        Display.pauseStatus(pause, now: now, calendar: utc, time: { _ in "TIME" }, dayAndTime: { _ in "DAY" })
    }

    @Test func notPausedOrExpiredOrUnrecognisedSaysNothing() {
        #expect(status(.off) == nil)
        #expect(status(.until(Date(timeIntervalSince1970: 1_790_377_200))) == nil)
        #expect(status(.unknown(type: "x", payload: .object([:]))) == nil)
    }

    @Test func eachKindOfPauseReadsAsItsOwnSentence() {
        #expect(status(.untilResumed) == "Paused until you resume")
        #expect(status(.until(Date(timeIntervalSince1970: 1_790_379_000))) == "Paused until TIME") // 23:30
        #expect(status(.until(Date(timeIntervalSince1970: 1_790_413_200)))
            == "Paused until tomorrow at TIME") // 09:00 next day
        #expect(status(.until(Date(timeIntervalSince1970: 1_790_499_600))) == "Paused until DAY") // +2 days
    }
}
