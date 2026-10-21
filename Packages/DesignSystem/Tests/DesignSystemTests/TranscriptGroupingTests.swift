import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// Messages-style grouping and day separators (`TranscriptGrouping`).
struct TranscriptGroupingTests {
    private static let alex = Member.ID("alex")
    private static let sam = Member.ID("sam")
    private static let space = Conversation.ID("space/s-1")

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    /// 2026-10-21 09:00 UTC, a Wednesday.
    private static let morning = Date(timeIntervalSince1970: 1_792_573_200)

    private static func message(
        _ id: String, _ sender: Member.ID = alex, minutes: Double, in conversation: Conversation.ID = space,
        call: MessageCallStatus? = nil
    ) -> Message {
        Message(
            id: Message.ID(id), conversationID: conversation, threadID: MessageThread.ID("t-\(id)"),
            sender: sender, text: id, createdAt: morning.addingTimeInterval(minutes * 60), callStatus: call
        )
    }

    private static func placements(
        _ messages: [Message], dividers: [Message.ID: Date] = [:]
    ) -> [TranscriptRowPlacement] {
        let result = TranscriptGrouping.placements(messages: messages, dividers: dividers, calendar: calendar)
        return messages.map { result[$0.id] ?? TranscriptRowPlacement() }
    }

    @Test func theSameSenderWithinFiveMinutesContinuesTheGroup() {
        let rows = Self.placements([
            Self.message("a", minutes: 0), Self.message("b", minutes: 1), Self.message("c", minutes: 5.9)
        ])
        #expect(rows.map(\.continuesGroup) == [false, true, true])
    }

    @Test func fiveMinutesOrMoreStartsAGroup() {
        let rows = Self.placements([Self.message("a", minutes: 0), Self.message("b", minutes: 5)])
        #expect(rows.map(\.continuesGroup) == [false, false])
    }

    @Test func anotherSenderStartsAGroup() {
        let rows = Self.placements([
            Self.message("a", minutes: 0),
            Self.message("b", Self.sam, minutes: 1),
            Self.message("c", minutes: 2)
        ])
        #expect(rows.map(\.continuesGroup) == [false, false, false])
    }

    /// A call card is an event, not speech: it stands alone, and the
    /// message after it shows its sender again.
    @Test func aCallCardNeitherContinuesNorIsContinued() {
        let rows = Self.placements([
            Self.message("a", minutes: 0), Self.message("call", minutes: 1, call: .ended),
            Self.message("c", minutes: 2)
        ])
        #expect(rows.map(\.continuesGroup) == [false, false, false])
    }

    @Test func aMessageOutOfOrderStartsAGroup() {
        let rows = Self.placements([Self.message("a", minutes: 3), Self.message("b", minutes: 1)])
        #expect(rows.map(\.continuesGroup) == [false, false])
    }

    @Test func eachDayGetsOneSeparatorAndNeverContinuesAcrossIt() {
        let rows = Self.placements([
            Self.message("a", minutes: 0), Self.message("b", minutes: 2),
            Self.message("late", minutes: 14 * 60 + 58), Self.message("next", minutes: 15 * 60 + 1)
        ])
        let day = Self.calendar.startOfDay(for: Self.morning)
        let next = Self.calendar.date(byAdding: .day, value: 1, to: day)
        #expect(rows.map(\.day) == [day, nil, nil, next])
        #expect(rows.map(\.continuesGroup) == [false, true, false, false])
    }

    /// A meeting occurrence's divider already dates its message, and starts
    /// a new group.
    @Test func aMeetingDividerReplacesTheSeparatorAndBreaksTheGroup() {
        let other = Conversation.ID("space/s-2")
        let messages = [Self.message("a", minutes: 0), Self.message("b", minutes: 1, in: other)]
        let rows = Self.placements(
            messages,
            dividers: [messages[0].id: Self.morning, messages[1].id: Self.morning]
        )
        #expect(rows.map(\.day) == [nil, nil])
        #expect(rows.map(\.continuesGroup) == [false, false])
    }

    @Test func dayLabelsReadLikeMessages() {
        let calendar = Self.calendar
        let locale = Locale(identifier: "en_US")
        let now = Self.morning
        func label(daysAgo: Int) -> String {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            return TranscriptDayLabel.text(for: day, now: now, calendar: calendar, locale: locale)
        }
        #expect(label(daysAgo: 0) == "Today")
        #expect(label(daysAgo: 1) == "Yesterday")
        #expect(label(daysAgo: 2) == "Monday")
        #expect(label(daysAgo: 6) == "Thursday")
        #expect(label(daysAgo: 7) == "Wed, Oct 14")
        #expect(label(daysAgo: 365) == "Oct 21, 2025")
    }

    @Test func aRowUnderASeparatorShowsOnlyItsTime() {
        let text = TranscriptDayLabel.time(
            of: Self.morning, calendar: Self.calendar, locale: Locale(identifier: "en_US")
        )
        // ICU puts a narrow no-break space before AM.
        #expect(text.replacingOccurrences(of: "\u{202F}", with: " ") == "9:00 AM")
    }
}
