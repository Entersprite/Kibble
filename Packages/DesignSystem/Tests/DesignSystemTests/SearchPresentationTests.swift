import ChatKit
import Foundation
import SwiftUI
import Testing
@testable import DesignSystem

/// What a hit row and the bar say (search spec §1.2, §1.4).
struct SearchPresentationTests {
    @Test func wordsAreFoldedAndSplit() {
        #expect(SearchPresentation.words("  Déploy  NOW ") == ["deploy", "now"])
    }

    @Test func aLateMatchIsBroughtIntoTheSnippet() {
        let text = String(repeating: "lorem ", count: 20) + "the deploy failed"
        let snippet = SearchPresentation.snippet(text, words: ["deploy"], lead: 36)
        #expect(snippet.hasPrefix("…"))
        #expect(snippet.contains("deploy failed"))
    }

    @Test func anEarlyMatchKeepsTheStart() {
        #expect(SearchPresentation.snippet("deploy now", words: ["deploy"], lead: 36) == "deploy now")
    }

    /// Accent- and case-insensitive, every occurrence of every word.
    @Test func everyMatchIsMarked() {
        let marked = SearchPresentation.highlighted("Déploy, then deploy again", words: ["deploy"])
        let runs = marked.runs.filter { $0.backgroundColor != nil }
            .map { String(marked[$0.range].characters) }
        #expect(runs == ["Déploy", "deploy"])
    }

    @Test func datesReadLikeMessages() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        calendar.locale = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 1_791_000_000) // Saturday 2026-10-03, 04:00 UTC
        #expect(SearchPresentation
            .shortDate(now.addingTimeInterval(-86400), now: now, calendar: calendar) == "Yesterday")
        #expect(SearchPresentation.shortDate(
            now.addingTimeInterval(-86400 * 3),
            now: now,
            calendar: calendar
        ) == "Wednesday")
        #expect(!SearchPresentation.shortDate(
            now.addingTimeInterval(-86400 * 30),
            now: now,
            calendar: calendar
        )
        .contains(":"))
    }

    @Test func theSummaryNamesWordsAndFilters() {
        let me = Member.ID("me")
        let alex = Member(id: Member.ID("alex"), kind: .human, displayName: "Alex Lee")
        let query = MessageSearchQuery(text: "deploy", from: alex.id, hasLink: true, mentionsMe: true)
        let summary = SearchPresentation.summary(
            of: query, directory: [alex.id: alex], conversations: [], me: me
        )
        #expect(summary == "“deploy” · from Alex Lee · has link · mentions me")
    }
}
