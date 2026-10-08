import ChatKit
import Foundation

/// The status menu's rows, from your availability and status at `now`
/// (set-your-status spec §5.1). Pure, so its words and checkmarks are tested.
struct StatusMenuModel: Equatable {
    struct DoNotDisturbChoice: Hashable {
        let title: String
        /// `nil` is 9:00 the next morning.
        let minutes: Double?

        /// When it ends if chosen at `now`. Counted from the click, never
        /// from when the menu was built: a menu's content is built with the
        /// view, and the footer may not have redrawn for hours (review
        /// finding 2).
        func until(now: Date, calendar: Calendar) -> Date? {
            if let minutes {
                return now.addingTimeInterval(minutes * 60)
            }
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            else { return nil }
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
        }
    }

    private(set) var isAutomatic = false
    private(set) var isAway = false
    private(set) var isDoNotDisturb = false
    private(set) var doNotDisturbTitle = "Do not disturb"
    let doNotDisturbChoices: [DoNotDisturbChoice]
    /// "🏠 Working remotely · until 17:00"; `nil` when no status is set, which
    /// also hides Clear Status.
    let statusLine: String?

    init(
        availability: Availability?,
        status: MemberStatus?,
        now: Date,
        calendar: Calendar = .current,
        time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) },
        day: (Date) -> String = { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }
    ) {
        switch availability {
        case let .doNotDisturb(until) where until > now:
            isDoNotDisturb = true
            doNotDisturbTitle = "Do not disturb until \(time(until))"
        case .doNotDisturb, .automatic:
            // Ruling 4: an ended Do not disturb is Automatic again.
            isAutomatic = true
        case .away:
            isAway = true
        case .unknown, nil:
            break
        }
        doNotDisturbChoices = Self.choices
        statusLine = status.flatMap { current in
            guard !current.isEmpty else { return nil }
            let until = current.expiresAt.map { end in
                " · until " + (calendar.isDate(end, inSameDayAs: now) ? time(end) : day(end))
            }
            return Display.statusSummary(current) + (until ?? "")
        }
    }

    /// 30 minutes to 8 hours, and 9:00 the next morning.
    private static let choices = [
        DoNotDisturbChoice(title: "For 30 minutes", minutes: 30),
        DoNotDisturbChoice(title: "For 1 hour", minutes: 60),
        DoNotDisturbChoice(title: "For 2 hours", minutes: 120),
        DoNotDisturbChoice(title: "For 4 hours", minutes: 240),
        DoNotDisturbChoice(title: "For 8 hours", minutes: 480),
        DoNotDisturbChoice(title: "Until tomorrow", minutes: nil)
    ]
}

extension Display {
    /// When the footer next changes: your marks' boundaries and the end of
    /// Do not disturb, after `now`, in order (ruling 8).
    static func ownRedrawDates(for member: Member?, availability: Availability?, now: Date) -> [Date] {
        var dates = redrawDates(for: member, now: now)
        if case let .doNotDisturb(until) = availability, until > now {
            dates.append(until)
        }
        return Set(dates).sorted()
    }
}
