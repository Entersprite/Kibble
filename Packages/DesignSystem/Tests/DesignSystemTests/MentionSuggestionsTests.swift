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

    // MARK: - The directory section (mention non-members spec §2)

    private func outsiders(_ count: Int) -> [Member] {
        (0 ..< count).map { person("out-\($0)", "Outsider \($0)") }
    }

    @Test func directoryPeopleFollowTheMembersMarkedOutside() {
        let rows = MentionSuggestions.suggestions(
            for: "", candidates: [person("1", "Jane Doe")], includeAll: false, directory: outsiders(1)
        )
        #expect(rows.map(\.name) == ["Jane Doe", "Outsider 0"])
        #expect(rows.map(\.outsideConversation) == [false, true])
    }

    @Test func aDirectoryPersonAlreadyAMemberIsShownOnce() {
        let jane = person("1", "Jane Doe")
        let rows = MentionSuggestions.suggestions(
            for: "",
            candidates: [jane],
            includeAll: false,
            directory: [jane]
        )
        #expect(rows.count == 1)
        #expect(rows.first?.outsideConversation == false)
    }

    @Test func theDirectorySectionIsCappedAtFive() {
        let rows = MentionSuggestions.suggestions(
            for: "",
            candidates: [],
            includeAll: false,
            directory: outsiders(8)
        )
        #expect(rows.count == MentionSuggestions.directoryLimit)
    }

    /// The server matched them: a nickname or another field may be why, so
    /// they are not matched again here.
    @Test func directoryPeopleAreNotRefilteredLocally() {
        let rows = MentionSuggestions.suggestions(
            for: "zz", candidates: [], includeAll: false, directory: [person("9", "Robert Smith")]
        )
        #expect(rows.map(\.name) == ["Robert Smith"])
    }

    /// Review finding 4: a member past the members section's cap, whom the
    /// server also returns, is a member, never "Not in this space".
    @Test func aMemberBeyondTheCapIsNeverShownAsOutside() {
        let members = (0 ..< 10).map { person("m-\($0)", "Member \($0)") }
        let rows = MentionSuggestions.suggestions(
            for: "", candidates: members, includeAll: false, directory: [members[9]]
        )
        #expect(!rows.contains { $0.outsideConversation })
    }
}
