import ChatKit
import SwiftUI

/// A person's calendar status beside their name: a symbol, with the words on
/// hover (meeting indicator spec §6.2).
struct CalendarMark: View {
    let symbol: String
    let words: String

    var body: some View {
        Image(systemName: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            // The name gives way, never the mark.
            .fixedSize()
            .help(words)
            .accessibilityElement()
            .accessibilityLabel("Calendar: \(words)")
    }
}

/// A person's custom status mark, then their calendar mark, at one moment.
///
/// **Failable:** with nothing to draw there is no view at all, so a caller's
/// stack gives it no spacing and no name truncates sooner (the whole-branch
/// review's finding 3; an empty view, even an empty `TimelineView`, still
/// takes the spacing). The caller wraps its whole stack in a `TimelineView`
/// over `Display.redrawDates`, so the marks change exactly at each boundary
/// and never otherwise (spec §6.3).
struct PersonMarks: View {
    private let status: MemberStatus?
    private let calendar: (symbol: String, words: String)?

    init?(status: MemberStatus?, calendar entry: CalendarSchedule.Entry?, now: Date) {
        let calendar = entry.flatMap { entry in
            Display.calendarSymbol(entry.kind).flatMap { symbol in
                Display.calendarSummary(entry, now: now).map { (symbol: symbol, words: $0) }
            }
        }
        guard status != nil || calendar != nil else { return nil }
        self.status = status
        self.calendar = calendar
    }

    var body: some View {
        HStack(spacing: 4) {
            if let status {
                StatusMark(status: status)
            }
            if let calendar {
                CalendarMark(symbol: calendar.symbol, words: calendar.words)
            }
        }
    }
}
