import ChatKit
import Foundation

/// When a custom status clears (set-your-status spec §5.2).
enum StatusExpiry: CaseIterable, Hashable, Sendable {
    case never, thirtyMinutes, oneHour, fourHours, today, thisWeek

    var title: String {
        switch self {
        case .never: "Don't clear"
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        case .fourHours: "4 hours"
        case .today: "Today"
        case .thisWeek: "This week"
        }
    }

    /// `nil` never clears. Today ends at the next midnight and this week at
    /// the start of the next, both in `calendar` (the locale's first weekday).
    func date(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .never: nil
        case .thirtyMinutes: now.addingTimeInterval(1800)
        case .oneHour: now.addingTimeInterval(3600)
        case .fourHours: now.addingTimeInterval(14400)
        case .today: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        case .thisWeek: calendar.dateInterval(of: .weekOfYear, for: now)?.end
        }
    }
}

/// A one-click status (spec §5.2).
struct StatusPreset: Hashable, Sendable {
    let emoji: String
    let text: String
    let expiry: StatusExpiry

    static let all = [
        StatusPreset(emoji: "📅", text: "In a meeting", expiry: .oneHour),
        StatusPreset(emoji: "🚌", text: "Commuting", expiry: .thirtyMinutes),
        StatusPreset(emoji: "🤒", text: "Out sick", expiry: .today),
        StatusPreset(emoji: "🌴", text: "On vacation", expiry: .never),
        StatusPreset(emoji: "🏠", text: "Working remotely", expiry: .today)
    ]
}

/// The sheet's state: what Save would send.
struct StatusDraft: Equatable {
    var emoji: String
    var text: String
    /// `nil` keeps `kept`, the end the current status already has (ruling 5).
    var expiry: StatusExpiry?
    let kept: Date?

    init(current: MemberStatus?) {
        emoji = current?.emoji ?? ""
        text = current?.text ?? ""
        kept = current?.expiresAt
        expiry = kept == nil ? .never : nil
    }

    mutating func apply(_ preset: StatusPreset) {
        emoji = preset.emoji
        text = preset.text
        expiry = preset.expiry
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSave: Bool {
        !emoji.isEmpty || !trimmedText.isEmpty
    }

    func status(now: Date, calendar: Calendar) -> MemberStatus? {
        guard canSave else { return nil }
        let end: Date? = if let expiry {
            expiry.date(now: now, calendar: calendar)
        } else {
            kept
        }
        return MemberStatus(
            emoji: emoji.isEmpty ? nil : emoji,
            text: trimmedText.isEmpty ? nil : trimmedText,
            expiresAt: end
        )
    }

    /// "As set, until 17:00": the Clear after choice that keeps `kept`.
    func keptTitle(
        now: Date,
        calendar: Calendar = .current,
        time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) },
        day: (Date) -> String = { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }
    ) -> String? {
        kept.map { "As set, until " + (calendar.isDate($0, inSameDayAs: now) ? time($0) : day($0)) }
    }
}
