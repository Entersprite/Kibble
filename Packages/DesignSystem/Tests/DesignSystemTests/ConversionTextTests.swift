import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// What the Convert to Space sheet says about a conversion: one line per
/// confirmed consequence, and one summary of what can't be confirmed.
struct ConversionTextTests {
    /// The LocalBridge answer, built literally: DesignSystem depends on ChatKit only.
    private let localBridge = ConversionConsequences(
        items: [ConversionConsequence(topic: .sameConversation, outcome: .kept)]
            + [
                ConversionTopic.membership,
                .messages,
                .history,
                .invitations,
                .integrations,
                .externalPeople,
                .undo
            ]
            .map { ConversionConsequence(topic: $0, outcome: .unknown) },
        requiresHistoryAcknowledgement: true
    )

    @Test func localBridgeConsequencesProduceOneLineAndAnUnknownSummary() throws {
        #expect(localBridge.items.compactMap(ConversionText.line) == ["It stays the same conversation."])
        let summary = try #require(ConversionText.unknownSummary(localBridge.items))
        #expect(summary == "Kibble can’t confirm what happens to members, messages, conversation "
            + "history settings, invitations, apps and webhooks, or external people. Kibble also "
            + "can’t confirm whether this can be undone.")
        #expect(localBridge.requiresHistoryAcknowledgement)
    }

    @Test func unknownTopicsProduceNoLine() {
        for outcome in [ConversionOutcome.kept, .changed, .notReversible, .unknown] {
            #expect(ConversionText.line(ConversionConsequence(topic: .unknown, outcome: outcome)) == nil)
            #expect(ConversionText
                .line(ConversionConsequence(topic: .init("archive"), outcome: outcome)) == nil)
        }
        let unnamed = [
            ConversionConsequence(topic: .unknown, outcome: .unknown),
            ConversionConsequence(topic: .init("archive"), outcome: .unknown)
        ]
        #expect(ConversionText.unknownSummary(unnamed) == nil, "A topic Kibble can't name isn't listed.")
    }

    @Test func eachConfirmedOutcomeHasItsLine() {
        let lines: [(ConversionConsequence, String)] = [
            (.init(topic: .sameConversation, outcome: .kept), "It stays the same conversation."),
            (.init(topic: .membership, outcome: .kept), "Everyone in it stays a member."),
            (.init(topic: .messages, outcome: .kept), "All messages are kept."),
            (.init(topic: .undo, outcome: .notReversible), "This can’t be undone."),
            (.init(topic: .history, outcome: .changed), "Conversation history settings will change.")
        ]
        for (consequence, line) in lines {
            #expect(ConversionText.line(consequence) == line)
        }
    }

    @Test func unknownOutcomesAndOtherCombinationsProduceNoLine() {
        let silent: [(ConversionTopic, ConversionOutcome)] = [
            (.sameConversation, .unknown), (.membership, .changed), (.messages, .notReversible),
            (.history, .kept), (.invitations, .kept), (.undo, .kept), (.undo, .unknown),
            (.externalPeople, .changed), (.integrations, .init("dropped"))
        ]
        for (topic, outcome) in silent {
            #expect(ConversionText.line(ConversionConsequence(topic: topic, outcome: outcome)) == nil)
        }
    }

    /// A token decoded with extra fields is still the same topic and outcome.
    @Test func tokensWithExtraFieldsStillMatch() throws {
        let json = #"{"topic":{"type":"undo","since":"v2"},"outcome":{"type":"notReversible","x":1}}"#
        let item = try JSONDecoder().decode(ConversionConsequence.self, from: Data(json.utf8))
        #expect(ConversionText.line(item) == "This can’t be undone.")
    }

    @Test func summaryListsUnknownTopicsInOrderOnce() {
        func unknown(_ topics: ConversionTopic...) -> [ConversionConsequence] {
            topics.map { ConversionConsequence(topic: $0, outcome: .unknown) }
        }
        #expect(ConversionText.unknownSummary(unknown(.invitations, .integrations, .externalPeople))
            == "Kibble can’t confirm what happens to invitations, apps and webhooks, or external people.")
        #expect(ConversionText.unknownSummary(unknown(.messages, .invitations, .messages))
            == "Kibble can’t confirm what happens to messages or invitations.")
        #expect(ConversionText.unknownSummary(unknown(.integrations))
            == "Kibble can’t confirm what happens to apps and webhooks.")
        #expect(ConversionText.unknownSummary(unknown(.undo))
            == "Kibble can’t confirm whether this can be undone.")
        #expect(ConversionText.unknownSummary(unknown(.sameConversation, .undo))
            == "Kibble can’t confirm whether it stays the same conversation or whether this can be undone.")
        #expect(ConversionText.unknownSummary([
            ConversionConsequence(topic: .sameConversation, outcome: .kept),
            ConversionConsequence(topic: .undo, outcome: .notReversible)
        ]) == nil)
        #expect(ConversionText.unknownSummary([]) == nil)
    }
}

/// The sheet's own draft: when Convert is offered, and what it sends.
struct ConversionDraftTests {
    @Test func needsANameWithinTheServersLimit() {
        var draft = ConversionDraft(name: "")
        #expect(!draft.isNameValid(limit: 128))
        draft.name = "   "
        #expect(!draft.isNameValid(limit: 128), "A name of spaces is no name.")
        draft.name = "Launch Team"
        #expect(draft.isNameValid(limit: 128))
        #expect(draft.isNameValid(limit: nil), "No limit supplied, no length check.")
        draft.name = String(repeating: "👍🏽", count: 32)
        #expect(draft.isNameValid(limit: 128), "Counted as the server counts: UTF-16 units.")
        draft.name += "a"
        #expect(!draft.isNameValid(limit: 128))
        draft.name = "  Launch Team  " + String(repeating: " ", count: 200)
        #expect(draft.isNameValid(limit: 128), "Spaces around the name aren't sent, so aren't counted.")
    }

    @Test func sendsTheTrimmedNameTheEmojiAndTheAcknowledgement() {
        var draft = ConversionDraft(name: "  Launch Team ")
        #expect(draft.mutation == .convertToSpace(
            name: "Launch Team", emoji: nil, acknowledgingHistoryChange: true
        ))
        draft.emoji = "🚀"
        #expect(draft.mutation == .convertToSpace(
            name: "Launch Team", emoji: "🚀", acknowledgingHistoryChange: true
        ))
        draft.emoji = ""
        #expect(draft.mutation == .convertToSpace(
            name: "Launch Team", emoji: nil, acknowledgingHistoryChange: true
        ), "No emoji is the default icon.")
    }

    @Test func takesOnlyASingleEmoji() {
        var draft = ConversionDraft(name: "Launch Team")
        draft.choose("👍🏽")
        #expect(draft.emoji == "👍🏽", "A skin tone is still one character.")
        draft.choose("🚀🚀")
        #expect(draft.emoji == "👍🏽", "Two characters are refused by the server, so not taken.")
        draft.choose(nil)
        #expect(draft.emoji == "👍🏽", "A custom emoji has no character to send.")
    }

    private func group(allowing actions: Set<String> = ["details", "rename", "convertToSpace"])
        -> ConversationDetails {
        ConversationDetails(
            conversation: Conversation(id: .init("lunch"), kind: .groupDirectMessage, title: "Lunch Crew"),
            membership: .joined,
            allowedActions: actions,
            fieldLimits: ["name": 128]
        )
    }

    @Test func acknowledgementIsNeededOnlyWhenRequired() {
        var draft = ConversionDraft(name: "Launch Team")
        let details = group()
        let required = ConversionConsequences(requiresHistoryAcknowledgement: true)
        let notRequired = ConversionConsequences(requiresHistoryAcknowledgement: false)
        #expect(!draft.isReady(details: details, conversion: required))
        #expect(draft.isReady(details: details, conversion: notRequired))
        #expect(!draft.isReady(details: details, conversion: nil), "Not before the consequences arrive.")
        draft.acknowledged = true
        #expect(draft.isReady(details: details, conversion: required))
        draft.name = ""
        #expect(!draft.isReady(details: details, conversion: required))
    }

    @Test func usesTheCurrentDetailsNameLimit() {
        let draft = ConversionDraft(name: String(repeating: "a", count: 20))
        let ready = ConversionConsequences(requiresHistoryAcknowledgement: false)
        var details = group()
        #expect(draft.isReady(details: details, conversion: ready))
        details.fieldLimits["name"] = 10
        #expect(!draft.isReady(details: details, conversion: ready))
    }

    @Test func detailsWithoutPermissionAfterAReloadAreNotReady() {
        var draft = ConversionDraft(name: "Launch Team")
        draft.acknowledged = true
        let ready = ConversionConsequences(requiresHistoryAcknowledgement: true)
        #expect(draft.isReady(details: group(), conversion: ready))
        let reloaded = group(allowing: ["details", "rename"])
        #expect(!ConversionDraft.allows(reloaded))
        #expect(!draft.isReady(details: reloaded, conversion: ready), "The read took the permission away.")
        var space = group()
        space.conversation.kind = .space
        #expect(!draft.isReady(details: space, conversion: ready), "Already a space: nothing to convert.")
        #expect(!draft.isReady(details: nil, conversion: ready), "No current details, no Convert.")
    }

    @Test func notWhileTheConsequencesAreReadAgain() {
        var draft = ConversionDraft(name: "Launch Team")
        draft.acknowledged = true
        let ready = ConversionConsequences(requiresHistoryAcknowledgement: true)
        #expect(!draft.isReady(details: group(), conversion: ready, isLoadingConversion: true))
        #expect(draft.isReady(details: group(), conversion: ready, isLoadingConversion: false))
    }
}
