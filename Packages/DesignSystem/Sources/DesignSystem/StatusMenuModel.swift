import ChatKit
import Foundation

/// The status menu's rows, from your availability and status at `now`
/// (set-your-status spec §5.1). Pure, so its words and checkmarks are tested.
struct StatusMenuModel: Equatable {
    struct DoNotDisturbChoice: Hashable {
        let title: String
        let until: Date
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
        doNotDisturbChoices = Self.choices(now: now, calendar: calendar)
        statusLine = status.flatMap { current in
            guard !current.isEmpty else { return nil }
            let until = current.expiresAt.map { end in
                " · until " + (calendar.isDate(end, inSameDayAs: now) ? time(end) : day(end))
            }
            return Display.statusSummary(current) + (until ?? "")
        }
    }

    /// 30 minutes to 8 hours, and 9:00 the next morning in `calendar`.
    private static func choices(now: Date, calendar: Calendar) -> [DoNotDisturbChoice] {
        let spans: [(minutes: Double, title: String)] = [
            (30, "For 30 minutes"), (60, "For 1 hour"), (120, "For 2 hours"),
            (240, "For 4 hours"), (480, "For 8 hours")
        ]
        var choices = spans.map { span in
            DoNotDisturbChoice(title: span.title, until: now.addingTimeInterval(span.minutes * 60))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) {
            choices.append(DoNotDisturbChoice(title: "Until tomorrow", until: nine))
        }
        return choices
    }
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
