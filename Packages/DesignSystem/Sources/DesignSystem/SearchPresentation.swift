import ChatKit
import Foundation
import SwiftUI

/// What search rows and the bar say. Pure, so each rule is a test.
enum SearchPresentation {
    static func words(_ text: String) -> [String] {
        folded(text).split(separator: " ").map(String.init)
    }

    /// The text around the first match: the start, or an ellipsis and about
    /// half of `lead` before the match.
    static func snippet(_ text: String, words: [String], lead: Int = 36) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let first = words.first, let range = folded(flat).range(of: first) else { return flat }
        let offset = folded(flat).distance(from: folded(flat).startIndex, to: range.lowerBound)
        guard offset > lead else { return flat }
        return "…" + flat.dropFirst(offset - lead / 2)
    }

    /// Every occurrence of every word in semibold on a yellow tint.
    static func highlighted(_ text: String, words: [String]) -> AttributedString {
        var marked = AttributedString(text)
        for word in words where !word.isEmpty {
            var from = marked.startIndex
            while from < marked.endIndex,
                  let range = marked[from ..< marked.endIndex]
                  .range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) {
                marked[range].font = .callout.weight(.semibold)
                marked[range].backgroundColor = Color.yellow.opacity(0.35)
                from = range.upperBound
            }
        }
        return marked
    }

    /// The time today, Yesterday, the weekday within a week, else month and day.
    static func shortDate(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let locale = calendar.locale ?? .current
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(Date.FormatStyle(
                date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                timeZone: calendar.timeZone
            ))
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            style = style.weekday(.wide)
        } else {
            style = style.month(.abbreviated).day()
        }
        return date.formatted(style)
    }

    /// `“deploy” · from Alex Lee · in Deploys · older than … · has file · has link · mentions me`.
    static func summary(
        of query: MessageSearchQuery, directory: [Member.ID: Member], conversations: [Conversation],
        me: Member.ID?
    ) -> String {
        var parts: [String] = []
        let text = query.text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            parts.append("“\(text)”")
        }
        if let from = query.from {
            parts.append("from \(Display.name(of: from, in: directory))")
        }
        if let id = query.conversation, let conversation = conversations.first(where: { $0.id == id }) {
            parts.append("in \(Display.title(of: conversation, directory: directory, me: me))")
        }
        if let olderThan = query.olderThan {
            parts.append("older than \(olderThan.formatted(date: .abbreviated, time: .omitted))")
        }
        if query.hasFile {
            parts.append("has file")
        }
        if query.hasLink {
            parts.append("has link")
        }
        if query.mentionsMe {
            parts.append("mentions me")
        }
        return parts.joined(separator: " · ")
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
