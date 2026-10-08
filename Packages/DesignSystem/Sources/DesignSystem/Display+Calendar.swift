import ChatKit
import Foundation

/// Calendar status on screen (meeting indicator spec §6): the mark beside a
/// name, the words on hover and in the DM header. By `Display.status`'s
/// rules, except in the footer, which is the one place that shows you.
public extension Display {
    /// The entry worth drawing for `member` at `now`: connected, the local
    /// user known, and never them.
    static func calendar(
        of member: Member.ID,
        directory: [Member.ID: Member],
        me: Member.ID?,
        connection: ConnectionState,
        now: Date
    ) -> CalendarSchedule.Entry? {
        guard connection == .connected, let me, member != me else { return nil }
        return directory[member]?.calendar?.current(at: now)
    }

    /// A one-to-one DM's other person's; nothing for any other kind.
    static func calendar(
        of conversation: Conversation,
        directory: [Member.ID: Member],
        me: Member.ID?,
        connection: ConnectionState,
        now: Date
    ) -> CalendarSchedule.Entry? {
        guard let partner = dmPartner(of: conversation, directory: directory, me: me) else { return nil }
        return calendar(of: partner.id, directory: directory, me: me, connection: connection, now: now)
    }

    /// A one-to-one DM's other person, when the directory knows them.
    static func dmPartner(
        of conversation: Conversation,
        directory: [Member.ID: Member],
        me: Member.ID?
    ) -> Member? {
        guard conversation.kind == .directMessage, let me,
              let other = conversation.members.first(where: { $0 != me })
        else { return nil }
        return directory[other]
    }

    /// Your own entry, for the sidebar footer only.
    static func ownCalendar(
        directory: [Member.ID: Member],
        me: Member.ID?,
        connection: ConnectionState,
        now: Date
    ) -> CalendarSchedule.Entry? {
        guard connection == .connected, let me else { return nil }
        return directory[me]?.calendar?.current(at: now)
    }

    /// Your own custom status, for the sidebar footer only: `status`'s rules
    /// without "never you".
    static func ownStatus(
        directory: [Member.ID: Member],
        me: Member.ID?,
        connection: ConnectionState,
        now: Date
    ) -> MemberStatus? {
        guard connection == .connected, let me, let status = directory[me]?.status, !status.isEmpty
        else { return nil }
        if let expiresAt = status.expiresAt, expiresAt <= now {
            return nil
        }
        return status
    }

    /// The SF Symbol beside a name, or `nil` for a kind shown only in words.
    /// Checked with `NSImage(systemSymbolName:)` in the tests.
    static func calendarSymbol(_ kind: CalendarSchedule.Kind) -> String? {
        switch kind {
        case .inMeeting: "calendar"
        case .outOfOffice: "airplane"
        case .focusTime: "moon.fill"
        case .busy, .unknown: nil
        }
    }

    /// "In a meeting until 15:00", or `nil` for a kind this build does not
    /// know. `time` and `day` are injected for the tests, the way
    /// `pauseStatus` takes them.
    static func calendarSummary(
        _ entry: CalendarSchedule.Entry,
        now: Date,
        calendar: Calendar = .current,
        time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) },
        day: (Date) -> String = { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }
    ) -> String? {
        let until = entry.until
        switch entry.kind {
        case .inMeeting:
            return until.map { "In a meeting until \(time($0))" } ?? "In a meeting"
        case .focusTime:
            return until.map { "Focus time until \(time($0))" } ?? "Focus time"
        case .busy:
            return until.map { "Busy until \(time($0))" } ?? "Busy"
        case .outOfOffice:
            guard let until else { return "Out of office" }
            return calendar.isDate(until, inSameDayAs: now)
                ? "Out of office · back at \(time(until))"
                : "Out of office · back on \(day(until))"
        case .unknown:
            return nil
        }
    }

    /// When a person's marks next change: each calendar boundary, and their
    /// custom status's expiry, after `now`, in order.
    static func redrawDates(for member: Member?, now: Date) -> [Date] {
        let boundaries = member?.calendar?.boundaries(after: now) ?? []
        let expiry = [member?.status?.expiresAt].compactMap(\.self).filter { $0 > now }
        return Set(boundaries + expiry).sorted()
    }
}
