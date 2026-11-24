import Foundation
import Testing
@testable import DesignSystem

struct ConversationMuteDateTests {
    @Test(arguments: [(3, 20), (10, 23)])
    func workdayStartsAtEightAndSkipsTheWeekend(hour: Int, nextDay: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Budapest"))
        let input = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 20,
            hour: hour
        )))
        let expected = calendar.date(from: DateComponents(year: 2026, month: 11, day: nextDay, hour: 8))
        #expect(ConversationMuteSection.nextWorkday(from: input, calendar: calendar) == expected)
    }
}
