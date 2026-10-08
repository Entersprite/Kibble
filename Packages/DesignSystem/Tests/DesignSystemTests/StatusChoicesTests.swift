import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// "Clear after", the presets and the draft (set-your-status spec §5.2).
struct StatusChoicesTests {
    private static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.firstWeekday = 2 // Monday
        return calendar
    }

    private let utc = Self.calendar("UTC")
    /// Wednesday 7 October 2026, 14:30 UTC.
    private let now = Date(timeIntervalSince1970: 1_791_383_400)

    @Test func eachClearAfterLandsWhereItSays() {
        let thursday = Date(timeIntervalSince1970: 1_791_417_600)
        let monday = Date(timeIntervalSince1970: 1_791_763_200)
        #expect(StatusExpiry.never.date(now: now, calendar: utc) == nil)
        #expect(StatusExpiry.thirtyMinutes.date(now: now, calendar: utc) == now.addingTimeInterval(1800))
        #expect(StatusExpiry.oneHour.date(now: now, calendar: utc) == now.addingTimeInterval(3600))
        #expect(StatusExpiry.fourHours.date(now: now, calendar: utc) == now.addingTimeInterval(14400))
        #expect(StatusExpiry.today.date(now: now, calendar: utc) == thursday)
        #expect(StatusExpiry.thisWeek.date(now: now, calendar: utc) == monday)
    }

    /// The person's own midnight, not UTC's.
    @Test func todayEndsAtTheLocalMidnight() {
        let pacificMidnight = Date(timeIntervalSince1970: 1_791_442_800)
        #expect(StatusExpiry.today
            .date(now: now, calendar: Self.calendar("America/Los_Angeles")) == pacificMidnight)
    }

    @Test func theTitlesAreTheMenus() {
        #expect(StatusExpiry.allCases.map(\.title)
            == ["Don't clear", "30 minutes", "1 hour", "4 hours", "Today", "This week"])
    }

    @Test func aPresetFillsTheDraft() throws {
        #expect(StatusPreset.all.map(\.text)
            == ["In a meeting", "Commuting", "Out sick", "On vacation", "Working remotely"])
        var draft = StatusDraft(current: nil)
        try draft.apply(#require(StatusPreset.all.first { $0.text == "Commuting" }))
        #expect(draft.emoji == "🚌")
        #expect(draft.text == "Commuting")
        #expect(draft.expiry == .thirtyMinutes)
    }

    @Test func blankTextIsNotAStatus() {
        var draft = StatusDraft(current: nil)
        draft.text = "   "
        #expect(!draft.canSave)
        #expect(draft.status(now: now, calendar: utc) == nil)
        draft.emoji = "🌴"
        #expect(draft.canSave)
        #expect(draft.status(now: now, calendar: utc) == MemberStatus(emoji: "🌴"))
    }

    @Test func aNewDraftNeverClears() {
        let draft = StatusDraft(current: nil)
        #expect(draft.expiry == .never)
        #expect(draft.keptTitle(now: now, calendar: utc) == nil)
        #expect(StatusDraft(current: MemberStatus(text: "Heads down")).expiry == .never)
    }

    /// Ruling 5: a tweak keeps the end the status already has.
    @Test func theDraftOpensWithTheCurrentStatusAndKeepsItsEnd() {
        let end = now.addingTimeInterval(3600)
        var draft = StatusDraft(current: MemberStatus(emoji: "🏠", text: "Working remotely", expiresAt: end))
        #expect(draft.emoji == "🏠")
        #expect(draft.text == "Working remotely")
        #expect(draft.expiry == nil)
        #expect(draft.status(now: now, calendar: utc)?.expiresAt == end)
        #expect(draft.keptTitle(now: now, calendar: utc, time: { _ in "15:30" }) == "As set, until 15:30")
        draft.expiry = .never
        #expect(draft.status(now: now, calendar: utc)?.expiresAt == nil)
    }
}
