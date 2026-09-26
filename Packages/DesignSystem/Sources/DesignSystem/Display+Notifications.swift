import ChatKit
import Foundation

public extension Display {
    /// A section's name - the sidebar heading and the settings row alike.
    static func title(of section: SectionKey) -> String {
        switch section {
        case .directMessages: "Direct messages"
        case .groupChats: "Group chats"
        case .spaces: "Spaces"
        case .apps: "Apps"
        case .meetChats: "Meet Chats"
        case .other: "Other"
        case let .unknown(raw): raw
        }
    }

    static func title(of delivery: Delivery) -> String {
        switch delivery {
        case .off: "Off"
        case .notificationCenter: "Notification Center only"
        case .banner: "Banner"
        case .bannerAndSound: "Banner and sound"
        case let .unknown(raw): raw
        }
    }

    /// The "Notify about" control's items (mentions spec §4).
    static func title(of choice: NotifyChoice) -> String {
        switch choice {
        case .allMessages: "All messages"
        case .mentions: "Mentions only"
        case .nothing: "Nothing"
        }
    }

    static func title(of duration: PauseDuration) -> String {
        switch duration {
        case .oneHour: "For 1 Hour"
        case .untilTomorrow: "Until Tomorrow"
        case .untilResumed: "Until I Resume"
        }
    }

    /// What the pane and the menu bar say while paused, or `nil` when not -
    /// including a pause already over, and one this build does not know
    /// (`Pause.isActive(at:)`).
    static func pauseStatus(
        _ pause: Pause,
        now: Date,
        calendar: Calendar = .current,
        time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) },
        dayAndTime: (Date) -> String = { $0.formatted(date: .abbreviated, time: .shortened) }
    ) -> String? {
        guard pause.isActive(at: now) else { return nil }
        guard case let .until(end) = pause else { return "Paused until you resume" }
        if calendar.isDate(end, inSameDayAs: now) {
            return "Paused until \(time(end))"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(end, inSameDayAs: tomorrow) {
            return "Paused until tomorrow at \(time(end))"
        }
        return "Paused until \(dayAndTime(end))"
    }
}
