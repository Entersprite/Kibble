import ChatKit
import Foundation
import SwiftUI

/// How one transcript row sits among its neighbors.
struct TranscriptRowPlacement: Equatable {
    /// The row continues the previous message's group, so it draws no name,
    /// picture or time; it keeps the picture's column, and its read receipt
    /// and thread mark keep their places.
    var continuesGroup = false
    /// The start of the day a separator before the row names; `nil` draws
    /// none.
    var day: Date?
}

/// Messages-style grouping, pure so each rule is a test, built like
/// `MeetingTranscriptPresentation.dividers`.
///
/// A message continues the one before it when both are from the same
/// sender, on the same day, in the same conversation, less than five minutes
/// apart, and neither is a call card. Five minutes is about one burst of
/// typing: long enough that a thought sent as three messages reads as one,
/// short enough that a reply after a pause gets its sender back. A call card
/// is an event rather than speech, so it always stands alone and never
/// lends its header to the message after it.
///
/// A day separator comes before the first loaded message of each day. A
/// meeting occurrence's divider already dates the message it stands before,
/// so that message gets no separator, and it starts a new group either way.
enum TranscriptGrouping {
    static let window: TimeInterval = 5 * 60

    static func placements(
        messages: [Message], dividers: [Message.ID: Date] = [:], calendar: Calendar = .current
    ) -> [Message.ID: TranscriptRowPlacement] {
        var result: [Message.ID: TranscriptRowPlacement] = [:]
        result.reserveCapacity(messages.count)
        var previous: Message?
        var previousDay: Date?
        for message in messages {
            let day = calendar.startOfDay(for: message.createdAt)
            let divided = dividers[message.id] != nil
            var placement = TranscriptRowPlacement()
            if day != previousDay, !divided {
                placement.day = day
            }
            if let previous, !divided, day == previousDay {
                placement.continuesGroup = continues(message, after: previous)
            }
            result[message.id] = placement
            previous = message
            previousDay = day
        }
        return result
    }

    /// The pairwise rule, for two messages already known to share a day.
    static func continues(_ message: Message, after previous: Message) -> Bool {
        let gap = message.createdAt.timeIntervalSince(previous.createdAt)
        return message.sender == previous.sender
            && message.conversationID == previous.conversationID
            && message.callStatus == nil && previous.callStatus == nil
            && gap >= 0 && gap < window
    }
}

/// What a day separator says: Today, Yesterday, the weekday within the last
/// week, else the date, with the year only when it is not this one. `now` is
/// injected for the tests, the way `Display.timestamp` takes it.
enum TranscriptDayLabel {
    static func text(
        for day: Date, now: Date = .now, calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let base = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let gap = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: day), to: calendar.startOfDay(for: now)
        ).day
        switch gap {
        case 0: return "Today"
        case 1: return "Yesterday"
        case let days? where days > 1 && days < 7: return day.formatted(base.weekday(.wide))
        default:
            let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
            return day.formatted(
                sameYear
                    ? base.weekday(.abbreviated).month(.abbreviated).day()
                    : base.month(.abbreviated).day().year()
            )
        }
    }

    /// A row's own time once a separator above it names the day.
    static func time(
        of date: Date, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent
    ) -> String {
        date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .hour().minute())
    }
}

/// A centered day separator, drawn like `MeetingOccurrenceDivider`. A header
/// for VoiceOver, so its headings rotor walks the transcript by day.
struct TranscriptDaySeparator: View {
    let day: Date

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.separator).frame(height: 1)
            Text(TranscriptDayLabel.text(for: day))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .layoutPriority(1)
            Rectangle().fill(.separator).frame(height: 1)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
