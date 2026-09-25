import Foundation

public extension Pause {
    /// Whether notifications are paused at `date`. Evaluated at arrival
    /// time; nothing runs a timer (spec §2.5).
    ///
    /// **An unrecognised pause is not active**: a newer build's pause that
    /// this one can neither show nor resume would otherwise swallow every
    /// notification with no way out here.
    func isActive(at date: Date) -> Bool {
        switch self {
        case .off, .unknown: false
        case let .until(end): date < end
        case .untilResumed: true
        }
    }
}

/// The three ways to pause that the settings pane and the menu bar offer.
/// A UI choice, never encoded: what is saved is the `Pause` it produces.
public enum PauseDuration: CaseIterable, Hashable, Sendable {
    case oneHour
    /// 09:00 local on the next calendar day - literally tomorrow, even just
    /// after midnight.
    case untilTomorrow
    case untilResumed

    public func pause(from now: Date, calendar: Calendar) -> Pause {
        switch self {
        case .oneHour:
            return .until(now.addingTimeInterval(3600))
        case .untilTomorrow:
            let today = calendar.startOfDay(for: now)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now
            return .until(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow)
        case .untilResumed:
            return .untilResumed
        }
    }
}

public extension NotificationSettings {
    var pause: Pause {
        guard case let .pause(pause)? = record(for: .pause)?.value else { return .off }
        return pause
    }

    /// Replaces the pause record, or appends one. Resuming writes `.off` -
    /// clearing never deletes (spec §2.2).
    mutating func setPause(_ pause: Pause, at date: Date, by device: String) {
        let record = SettingsRecord(scope: .pause, value: .pause(pause), modifiedAt: date, modifiedBy: device)
        if let index = records.firstIndex(where: { $0.scope == .pause }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }
}
