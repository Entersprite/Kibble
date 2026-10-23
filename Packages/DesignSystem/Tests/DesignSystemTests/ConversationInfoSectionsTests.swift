import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// Which sections the Info sheet's sidebar lists, and the one-draft rule that
/// guards switching between them and closing the sheet.
struct ConversationInfoSectionsTests {
    private let everything = Capabilities(extendedFlags: [
        "conversationApps", "conversationWebhooks", "conversationEmail"
    ])

    private func details(
        _ kind: Conversation.Kind,
        settings: ConversationSettings? = nil
    ) -> ConversationDetails {
        ConversationDetails(
            conversation: Conversation(id: .init("c"), kind: kind, title: "Room"),
            membership: .joined,
            settings: settings
        )
    }

    @Test func aSpaceShowsAllFourSections() {
        let sections = ConversationInfoSections.available(
            for: details(.space, settings: ConversationSettings()),
            capabilities: everything
        )
        #expect(sections == [.people, .details, .settings, .integrations])
    }

    @Test func aSpaceWithoutSettingsHasNoSettingsSection() {
        let sections = ConversationInfoSections.available(for: details(.space), capabilities: everything)
        #expect(sections == [.people, .details, .integrations])
    }

    @Test func aOneToOneChatShowsPeopleAndIntegrationsOnly() {
        let sections = ConversationInfoSections.available(
            for: details(.directMessage, settings: ConversationSettings()),
            capabilities: everything
        )
        #expect(sections == [.people, .integrations])
    }

    @Test func aGroupChatHasNoSettings() {
        let sections = ConversationInfoSections.available(
            for: details(.groupDirectMessage, settings: ConversationSettings()),
            capabilities: everything
        )
        #expect(sections == [.people, .details, .integrations])
    }

    @Test func integrationsHideWhenNeitherAppsNorWebhooksAreAdvertised() {
        let space = details(.space, settings: ConversationSettings())
        #expect(
            ConversationInfoSections.available(
                for: space,
                capabilities: Capabilities(extendedFlags: ["conversationEmail"])
            ) == [.people, .details, .settings]
        )
        #expect(
            ConversationInfoSections.available(
                for: space,
                capabilities: Capabilities(extendedFlags: ["conversationWebhooks"])
            ) == [.people, .details, .settings, .integrations]
        )
        #expect(
            ConversationInfoSections.available(
                for: space,
                capabilities: Capabilities(extendedFlags: ["conversationApps"])
            ) == [.people, .details, .settings, .integrations]
        )
    }

    @Test func meetAndAppChatsListPeopleOnlyWhenParticipantsAreAvailable() {
        for kind in [Conversation.Kind.meetChat, .appDirectMessage] {
            #expect(
                ConversationInfoSections.available(for: details(kind), capabilities: everything)
                    == [.people, .details, .integrations]
            )
            #expect(
                ConversationInfoSections.available(
                    for: details(kind),
                    capabilities: Capabilities(),
                    hasParticipants: false
                ) == [.details]
            )
        }
    }

    @Test func aCleanDraftProceeds() {
        var drafts = InfoDraftState()
        #expect(drafts.request(.switchTo(.details)) == .proceed(.switchTo(.details)))
        #expect(drafts.request(.close) == .proceed(.close))
        #expect(drafts.dirtySection == nil)
    }

    @Test func aDirtyDraftAsksBeforeSwitchingOrClosing() {
        var drafts = InfoDraftState(dirtySection: .details)
        #expect(drafts.request(.switchTo(.people)) == .askToSave(.switchTo(.people)))
        #expect(drafts.request(.close) == .askToSave(.close))
        // Asking changes nothing: the draft stays until the section saves or reverts it.
        #expect(drafts.dirtySection == .details)
    }

    @Test func returningToTheDirtySectionNeedsNoQuestion() {
        var drafts = InfoDraftState(dirtySection: .settings)
        #expect(drafts.request(.switchTo(.settings)) == .proceed(.switchTo(.settings)))
    }
}
