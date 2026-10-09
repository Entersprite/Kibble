import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// The words under a message with replies (threads spec §5.1). Pure, from a
/// fixed clock, calendar and locale.
struct ThreadMarkTextTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let locale = Locale(identifier: "en_US_POSIX")

    private func thread(messages: Int, lastActivity: Date? = nil, unread: Bool = false) -> MessageThread {
        MessageThread(
            id: MessageThread.ID("t-1"), conversationID: Conversation.ID("space/s-1"),
            replyCount: messages, lastActivity: lastActivity, hasUnread: unread
        )
    }

    /// `replyCount` counts the first message, so 2 is one reply.
    @Test func theCountLeavesOutTheFirstMessage() {
        #expect(ThreadMarkText.count(thread(messages: 2)) == "1 reply")
        #expect(ThreadMarkText.count(thread(messages: 5)) == "4 replies")
    }

    @Test func recentRepliesAreSaidInMinutesHoursAndDays() {
        let text = { (seconds: TimeInterval) in
            ThreadMarkText.lastReply(
                at: now.addingTimeInterval(-seconds), now: now, calendar: calendar, locale: locale
            )
        }
        #expect(text(20) == "Last reply just now")
        #expect(text(5 * 60) == "Last reply 5m ago")
        #expect(text(2 * 3600) == "Last reply 2h ago")
        #expect(text(3 * 86400) == "Last reply 3d ago")
    }

    /// Older than a week, the transcript's own stamp: the same words a
    /// bubble's time uses, so the two never disagree.
    @Test func anOldReplyUsesTheTranscriptStamp() {
        let date = now.addingTimeInterval(-10 * 86400)
        let expected = "Last reply " + Display.timestamp(
            of: date, now: now, calendar: calendar, locale: locale
        )
        #expect(ThreadMarkText.lastReply(at: date, now: now, calendar: calendar, locale: locale) == expected)
    }

    /// A clock that ran backwards (another device's time) says "just now",
    /// never a negative number.
    @Test func aReplyFromTheFutureIsJustNow() {
        let text = ThreadMarkText.lastReply(
            at: now.addingTimeInterval(120), now: now, calendar: calendar, locale: locale
        )
        #expect(text == "Last reply just now")
    }

    /// Each band's edge, from both sides.
    @Test func theBandsChangeExactlyAtTheirEdges() {
        let text = { (seconds: TimeInterval) in
            ThreadMarkText.lastReply(
                at: now.addingTimeInterval(-seconds), now: now, calendar: calendar, locale: locale
            )
        }
        let week: TimeInterval = 7 * 86400
        let stamp = Display.timestamp(
            of: now.addingTimeInterval(-week), now: now, calendar: calendar, locale: locale
        )
        #expect(text(59) == "Last reply just now")
        #expect(text(60) == "Last reply 1m ago")
        #expect(text(3599) == "Last reply 59m ago")
        #expect(text(3600) == "Last reply 1h ago")
        #expect(text(86399) == "Last reply 23h ago")
        #expect(text(86400) == "Last reply 1d ago")
        #expect(text(week - 1) == "Last reply 6d ago")
        #expect(text(week) == "Last reply " + stamp)
    }

    /// VoiceOver hears the same bands with the units spelled out, and from a
    /// week on the same stamp the mark shows, never "400 days ago" beside a date.
    @Test func voiceOverUsesTheSameBandsAndTheStamp() {
        let spoken = { (seconds: TimeInterval) in
            ThreadMarkText.spoken(
                thread(messages: 2, lastActivity: now.addingTimeInterval(-seconds)),
                now: now, calendar: calendar, locale: locale
            )
        }
        let day: TimeInterval = 86400
        let week = 7 * day
        let old = 400 * day
        let stamp = Display.timestamp(
            of: now.addingTimeInterval(-old), now: now, calendar: calendar, locale: locale
        )
        #expect(spoken(59) == "1 reply, last reply just now")
        #expect(spoken(day) == "1 reply, last reply 1 day ago")
        #expect(spoken(week - 1) == "1 reply, last reply 6 days ago")
        #expect(spoken(old) == "1 reply, last reply " + stamp)
    }

    @Test func voiceOverHearsTheCountTheTimeAndUnread() {
        let read = thread(messages: 5, lastActivity: now.addingTimeInterval(-2 * 3600))
        #expect(ThreadMarkText.spoken(read, now: now) == "4 replies, last reply 2 hours ago")
        let unread = thread(messages: 2, lastActivity: now.addingTimeInterval(-60), unread: true)
        #expect(ThreadMarkText.spoken(unread, now: now) == "1 reply, last reply 1 minute ago, unread")
        #expect(ThreadMarkText.spoken(thread(messages: 3), now: now) == "2 replies")
    }
}
