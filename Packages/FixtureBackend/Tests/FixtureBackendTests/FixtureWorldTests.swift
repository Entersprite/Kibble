import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

/// `FixtureWorld` is data, and data that is quietly wrong renders as a UI bug
/// three layers up. These tests exist so a broken world fails here instead.
struct FixtureWorldTests {
    @Test func minimalWorldIsSelfConsistent() {
        #expect(FixtureWorld.minimal.inconsistencies().isEmpty)
    }

    @Test func inconsistenciesNameAMessageWhoseSenderIsUnknown() {
        var world = FixtureWorld.minimal
        world.messages[0].sender = Member.ID("nobody")
        #expect(world.inconsistencies().contains { $0.contains("nobody") })
    }

    @Test func inconsistenciesNameAConversationMemberWhoDoesNotExist() {
        var world = FixtureWorld.minimal
        world.conversations[0].members.append(Member.ID("ghost"))
        #expect(world.inconsistencies().contains { $0.contains("ghost") })
    }

    @Test func inconsistenciesNameAMessageInNoConversation() {
        var world = FixtureWorld.minimal
        world.messages[0].conversationID = Conversation.ID("space:nowhere")
        #expect(world.inconsistencies().contains { $0.contains("space:nowhere") })
    }

    @Test func inconsistenciesNoticeALocalUserWhoIsNotAMember() {
        var world = FixtureWorld.minimal
        world.me = Member.ID("stranger")
        #expect(world.inconsistencies().contains { $0.contains("stranger") })
    }

    @Test func messagesInAConversationAreThatConversationsInWorldOrder() {
        let world = FixtureWorld.minimal
        for conversation in world.conversations {
            let page = world.messages(in: conversation.id)
            #expect(!page.isEmpty)
            #expect(page.allSatisfy { $0.conversationID == conversation.id })
            #expect(page == page.sorted { $0.createdAt < $1.createdAt })
        }
    }

    @Test func membersInAConversationResolveToRecords() {
        let world = FixtureWorld.minimal
        for conversation in world.conversations {
            let resolved = world.members(in: conversation)
            #expect(resolved.map(\.id) == conversation.members)
        }
    }

    /// The demo world is elsewhere; `minimal` is what the suite runs against so
    /// that editing the demo cannot break these tests.
    @Test func minimalWorldHasBothAConversationKindThatMatters() {
        let kinds = Set(FixtureWorld.minimal.conversations.map(\.kind))
        #expect(kinds.contains(.directMessage))
        #expect(kinds.contains(.space))
    }
}
