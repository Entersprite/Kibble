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

/// A person's custom status mark, then their calendar mark, redrawn exactly
/// when either changes and never otherwise (spec §6.3). `marks` answers what
/// to draw at a moment, already gated; `member` names the moments.
struct PersonMarks: View {
    let member: Member?
    let marks: (Date) -> (status: MemberStatus?, calendar: CalendarSchedule.Entry?)

    var body: some View {
        TimelineView(.explicit(Display.redrawDates(for: member, now: .now))) { _ in
            // `.now`, not the timeline's date: a redraw for any other reason
            // must not draw the state of the last boundary.
            let now = Date.now
            let shown = marks(now)
            HStack(spacing: 4) {
                if let status = shown.status {
                    StatusMark(status: status)
                }
                if let entry = shown.calendar, let symbol = Display.calendarSymbol(entry.kind),
                   let words = Display.calendarSummary(entry, now: now) {
                    CalendarMark(symbol: symbol, words: words)
                }
            }
        }
    }
}
