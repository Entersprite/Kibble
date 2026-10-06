import ChatKit
import Testing
@testable import DesignSystem

struct MentionSuggestionsTests {
    private func person(_ id: String, _ name: String, _ email: String? = nil) -> Member {
        Member(id: Member.ID(id), kind: .human, displayName: name, email: email)
    }

    private var people: [Member] {
        [
            person("1", "Jane Doe", "jd@example.invalid"),
            person("2", "Zoë Ödegaard", "zoe@example.invalid"),
            person("3", "Bob Stone", "dora@example.invalid")
        ]
    }

    private func names(_ query: String, all: Bool = false) -> [String] {
        MentionSuggestions.suggestions(for: query, candidates: people, includeAll: all).map(\.name)
    }

    @Test func anEmptyQueryOffersEveryoneInOrder() {
        #expect(names("") == ["Jane Doe", "Zoë Ödegaard", "Bob Stone"])
    }

    @Test func anyWordOfTheNameMatchesByPrefix() {
        #expect(names("do") == ["Jane Doe", "Bob Stone"])
        #expect(names("sto") == ["Bob Stone"])
    }

    @Test func aQueryWithASpaceMatchesAcrossWords() {
        #expect(names("jane d") == ["Jane Doe"])
        #expect(names("jane x").isEmpty)
    }

    @Test func caseAndDiacriticsAreIgnored() {
        #expect(names("zoe") == ["Zoë Ödegaard"])
        #expect(names("ODE") == ["Zoë Ödegaard"])
    }

    @Test func theEmailsLocalPartMatches() {
        #expect(names("jd") == ["Jane Doe"])
        #expect(names("example").isEmpty)
    }

    @Test func allComesFirstOnlyWhenIncludedAndMatching() {
        #expect(names("", all: true).first == "all")
        #expect(names("al", all: true).first == "all")
        #expect(!names("al", all: false).contains("all"))
        #expect(!names("jane", all: true).contains("all"))
    }

    @Test func theListIsCapped() {
        let many = (0 ..< 20).map { person("\($0)", "Person \($0)") }
        #expect(MentionSuggestions.suggestions(for: "", candidates: many, includeAll: true)
            .count == MentionSuggestions.limit)
    }
}
