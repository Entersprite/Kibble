import ChatKit
import Testing
@testable import DesignSystem

/// The confirmation at Return, and what the composer takes from the host
/// for people outside a space or a group chat (mention non-members spec §2).
struct OutsideMentionsTests {
    private let jane = Member.ID("jane")
    private let bo = Member.ID("bo")

    private var message: ComposedMessage {
        ComposedMessage(text: "@Jane Doe hi @Bo", mentions: [
            Mention(target: .user(jane), start: 0, length: 9),
            Mention(target: .user(bo), start: 13, length: 3)
        ])
    }

    private func invite(
        _ people: [Member.ID],
        adding: ComposerOutsiders.Adding = .byMention,
        place: String = "space",
        host: Bool = true
    ) -> PendingInvite {
        PendingInvite(
            message: message, outsiders: ComposerOutsiders(people: people, adding: adding), place: place,
            canAddBeforeSending: host
        )
    }

    @Test func theQuestionNamesThePlace() {
        #expect(invite([jane]).title == "Jane Doe isn't in this space.")
        #expect(invite([jane, bo], place: "group chat").title == "Jane Doe and Bo aren't in this group chat.")
    }

    @Test func addingIsOfferedWhereTheyCanBeAdded() {
        #expect(invite([jane], adding: .byMention).offersAdding)
        #expect(invite([jane], adding: .beforeSending).offersAdding)
        #expect(!invite([jane], adding: .unavailable).offersAdding)
    }

    /// The host has to do the adding; without a way to, nobody is offered it.
    @Test func addingBeforeSendingNeedsAHostThatCan() {
        #expect(invite([jane], adding: .beforeSending, host: false).adding == .unavailable)
        #expect(invite([jane], adding: .byMention, host: false).adding == .byMention)
    }

    @Test func theLineUnderTheQuestionSaysWhatHappens() {
        #expect(invite([jane]).detail == "Adding them lets them see this message.")
        #expect(invite([jane], adding: .unavailable).detail
            == "They can't be added from here, so they won't see this message.")
    }

    @Test func aGroupChatIsCalledOne() {
        #expect(ComposerMentions.place(of: .groupDirectMessage) == "group chat")
        #expect(ComposerMentions.place(of: .space) == "space")
    }

    // MARK: - Which composer's query the directory answers

    private func people(_ query: String, answering answered: String?) -> [Member.ID] {
        ComposerMentions(
            candidates: [], includeAll: false,
            directory: [Member(id: Member.ID("out"), kind: .human, displayName: "Out")],
            directoryQuery: answered
        ).directory(for: query).map(\.id)
    }

    @Test func theDirectoryIsShownForTheQueryItAnswers() {
        #expect(people("ou", answering: "ou") == [Member.ID("out")])
    }

    /// The other composer's `@` was what was searched.
    @Test func theDirectoryIsNotShownForAnotherQuery() {
        #expect(people("ja", answering: "ou").isEmpty)
    }

    @Test func aDirectoryWithNoQueryAnswersAny() {
        #expect(people("ja", answering: nil) == [Member.ID("out")])
    }
}
