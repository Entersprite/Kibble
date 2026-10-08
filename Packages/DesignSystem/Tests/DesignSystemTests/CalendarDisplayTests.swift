import AppKit
import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// Which calendar entry is drawn, with which symbol and in what words
/// (meeting indicator spec §6).
struct CalendarDisplayTests {
    private let me = Member.ID("me")
    private let ada = Member.ID("u-1")
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func after(_ minutes: Double) -> Date {
        now.addingTimeInterval(minutes * 60)
    }

    private func entry(_ kind: CalendarSchedule.Kind, until: Date?) -> CalendarSchedule.Entry {
        .init(start: after(-10), end: after(50), kind: kind, until: until)
    }

    private func directory(_ entry: CalendarSchedule.Entry?, status: MemberStatus? = nil) -> [Member.ID: Member] {
        let schedule = entry.map { CalendarSchedule(entries: [$0], validUntil: nil) }
        return [
            ada: Member(id: ada, kind: .human, displayName: "Ada", status: status, calendar: schedule),
            me: Member(id: me, kind: .human, displayName: "Me", status: MemberStatus(emoji: "🏠"), calendar: schedule)
        ]
    }

    /// Fixed words for times, so no test depends on the machine's locale.
    private func words(_ entry: CalendarSchedule.Entry) -> String? {
        Display.calendarSummary(
            entry, now: now, calendar: utc, time: { _ in "15:00" }, day: { _ in "Fri 9 Oct" }
        )
    }

    @Test func eachKindHasItsWords() {
        #expect(words(entry(.inMeeting, until: after(60))) == "In a meeting until 15:00")
        #expect(words(entry(.focusTime, until: after(60))) == "Focus time until 15:00")
        #expect(words(entry(.busy, until: after(60))) == "Busy until 15:00")
        #expect(words(entry(.unknown("huddle"), until: after(60))) == nil)
    }

    @Test func withNoUntilTheWordsAreTheStateAlone() {
        #expect(words(entry(.inMeeting, until: nil)) == "In a meeting")
        #expect(words(entry(.outOfOffice, until: nil)) == "Out of office")
    }

    /// "Back at" today, "back on" another day.
    @Test func outOfOfficeSaysWhenTheyAreBack() {
        #expect(words(entry(.outOfOffice, until: after(60))) == "Out of office · back at 15:00")
        #expect(words(entry(.outOfOffice, until: after(60 * 48))) == "Out of office · back on Fri 9 Oct")
    }

    @Test func busyAndUnknownKindsHaveNoMark() {
        #expect(Display.calendarSymbol(.inMeeting) == "calendar")
        #expect(Display.calendarSymbol(.outOfOffice) == "airplane")
        #expect(Display.calendarSymbol(.focusTime) == "moon.fill")
        #expect(Display.calendarSymbol(.busy) == nil)
        #expect(Display.calendarSymbol(.unknown("huddle")) == nil)
    }

    /// A wrong symbol name compiles and draws nothing.
    @Test func everySymbolExists() {
        for kind in [CalendarSchedule.Kind.inMeeting, .outOfOffice, .focusTime] {
            let name = Display.calendarSymbol(kind) ?? ""
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }

    @Test func anotherPersonsEntryIsShownWhileConnectedOnly() {
        let shown = entry(.inMeeting, until: after(60))
        let people = directory(shown)
        #expect(Display.calendar(of: ada, directory: people, me: me, connection: .connected, now: now) == shown)
        #expect(Display.calendar(of: ada, directory: people, me: me, connection: .connecting, now: now) == nil)
        #expect(Display.calendar(of: ada, directory: people, me: nil, connection: .connected, now: now) == nil)
    }

    /// The local user's marks are drawn only in the footer, through its own
    /// functions.
    @Test func yourOwnEntryAndStatusOnlyThroughTheFootersFunctions() {
        let shown = entry(.focusTime, until: after(60))
        let people = directory(shown)
        #expect(Display.calendar(of: me, directory: people, me: me, connection: .connected, now: now) == nil)
        #expect(Display.ownCalendar(directory: people, me: me, connection: .connected, now: now) == shown)
        #expect(Display.ownStatus(directory: people, me: me, connection: .connected, now: now)?.emoji == "🏠")
        #expect(Display.ownStatus(directory: people, me: me, connection: .connecting, now: now) == nil)
    }

    @Test func aDMsPartnerIsTheOtherMember() {
        let dm = Conversation(id: .init("dm:1"), kind: .directMessage, members: [me, ada])
        let space = Conversation(id: .init("space:1"), kind: .space, members: [me, ada])
        let people = directory(nil)
        #expect(Display.dmPartner(of: dm, directory: people, me: me)?.id == ada)
        #expect(Display.dmPartner(of: space, directory: people, me: me) == nil)
    }

    /// Calendar boundaries and the custom status's expiry, after now, in order.
    @Test func redrawDatesAreEveryLaterBoundaryAndTheStatusExpiry() {
        let member = Member(
            id: ada, kind: .human,
            status: MemberStatus(emoji: "🌴", expiresAt: after(20)),
            calendar: CalendarSchedule(entries: [entry(.inMeeting, until: after(60))], validUntil: after(90))
        )
        #expect(Display.redrawDates(for: member, now: now) == [after(20), after(50), after(90)])
        #expect(Display.redrawDates(for: nil, now: now).isEmpty)
    }

    @Test func theHeaderReadsPresenceThenCalendarThenStatus() {
        #expect(Display.headerSubtitle(
            presence: .inactive, calendar: "In a meeting until 15:00", status: MemberStatus(emoji: "🌴", text: "Away")
        ) == "Away · In a meeting until 15:00 · 🌴 Away")
        #expect(Display.headerSubtitle(presence: nil, calendar: "Busy until 15:00", status: nil) == "Busy until 15:00")
    }
}
