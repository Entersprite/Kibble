import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct ConversationIntegrationsTests {
    @Test func serializedQueriesRemainEphemeralAndDoNotSendCommands() async throws {
        let harness = try await ReconciliationHarness.make(webhooks: true)
        let value = ConversationIntegrations(webhooks: [ConversationWebhook(
            id: "hook", name: "Builds", allowedActions: ["editWebhook"]
        )], canCreateWebhook: true)
        await harness.backend.setIntegrations(value)
        do {
            #expect(try await harness.call(GetConversationIntegrations(
                conversationID: .init("ephemeral")
            )) == value)
            let url = try await harness.call(GetWebhookDeliveryURL(
                webhookID: "hook", conversationID: .init("ephemeral")
            ))
            #expect(url.absoluteString == "https://example.invalid/private-delivery-key")
            #expect(try harness.storage.conversation(.init("ephemeral")) == nil)
            #expect(await harness.backend.sentCommands.isEmpty)
        } catch {
            await harness.service.shutdown()
            throw error
        }
        await harness.service.shutdown()
    }

    @Test func unsupportedProviderIsRefusedBeforeQueryDispatch() async throws {
        let harness = try await ReconciliationHarness.make()
        await #expect(throws: (any Error).self) {
            _ = try await harness.call(GetConversationIntegrations(conversationID: .init("room")))
        }
        await #expect(throws: (any Error).self) {
            _ = try await harness.call(GetWebhookDeliveryURL(
                webhookID: "hook",
                conversationID: .init("room")
            ))
        }
        #expect(await harness.backend.integrationReads == 0)
        #expect(await harness.backend.deliveryURLReads == 0)
        await harness.service.shutdown()
    }

    @Test func disabledAccountCannotReceiveHeldDeliveryURL() async throws {
        let harness = try await ReconciliationHarness.make(webhooks: true)
        await harness.backend.setIntegrations(ConversationIntegrations(), holdURL: true)
        let query = Task { try await harness.call(GetWebhookDeliveryURL(
            webhookID: "hook", conversationID: .init("room")
        )) }
        do {
            try await authEventually { await harness.backend.deliveryURLHeld }
            let disabling = Task { try await harness.call(SetAccountEnabled(enabled: false)) }
            try await authEventually { try harness.registry.accounts().first?.isEnabled == false }
            await harness.backend.releaseDeliveryURL()
            _ = try await disabling.value
            await #expect(throws: (any Error).self) { _ = try await query.value }
        } catch {
            await harness.backend.releaseDeliveryURL()
            _ = await query.result
            await harness.service.shutdown()
            throw error
        }
        await harness.service.shutdown()
    }

    @Test func partialCapabilitiesFilterProviderListingBeforeItReachesTheClient() async throws {
        let harness = try await ReconciliationHarness.make(integrationsFlags: ["conversationApps"])
        let app = ConversationApp(member: Member(id: .init("app"), kind: .app))
        await harness.backend.setIntegrations(ConversationIntegrations(
            webhooks: [ConversationWebhook(id: "hidden", name: "Hidden")], canCreateWebhook: true,
            apps: [app], canAddApps: true
        ))
        let listing = try await harness.call(GetConversationIntegrations(conversationID: .init("room")))
        #expect(listing.apps == [app] && listing.canAddApps)
        #expect(listing.webhooks.isEmpty && !listing.canCreateWebhook)
        await harness.service.shutdown()
    }

    @Test func appAndEmailOperationsCrossSerializerAndOpeningReplaysOnce() async throws {
        let harness = try await ReconciliationHarness.make(integrationsFlags: [
            "conversationApps", "conversationEmail"
        ])
        let app = ConversationApp(member: Member(id: .init("app"), kind: .app))
        await harness.backend.setIntegrations(ConversationIntegrations(apps: [app], canAddApps: true))
        #expect(try await harness
            .call(SearchConversationApps(query: "", conversationID: .init("room"))) == [app])
        #expect(try await harness.call(GetConversationEmail(conversationID: .init("room")))
            .address == "room@example.invalid")
        let opening = OpenConversationApp(
            appID: app.id,
            conversationID: .init("room"),
            operationID: .init("open")
        )
        let first = try await harness.call(opening)
        #expect(try await harness.call(opening) == first)
        #expect(first.kind == .appDirectMessage && first.members == [app.id])
        #expect(await harness.backend.appOpens == 1)
        let mutation = MutateConversation(
            mutation: .setEmailDelivery(false), conversationID: .init("room"),
            operationID: .init("delivery"), expectedRevision: "old"
        )
        _ = try await harness.call(mutation)
        _ = try await harness.call(mutation)
        #expect(await harness.backend.managementMutations == [.setEmailDelivery(false)])
        await harness.service.shutdown()
    }

    @Test func absentFlagsRefuseReadsAndWritesBeforeProviderDispatch() async throws {
        let harness = try await ReconciliationHarness.make()
        await #expect(throws: (any Error).self) {
            _ = try await harness.call(SearchConversationApps(query: "", conversationID: .init("room")))
        }
        await #expect(throws: (any Error).self) {
            _ = try await harness.call(GetConversationEmail(conversationID: .init("room")))
        }
        await #expect(throws: (any Error).self) {
            _ = try await harness.call(OpenConversationApp(
                appID: .init("app"), conversationID: .init("room"), operationID: .init("open")
            ))
        }
        for (index, mutation) in [
            ConversationMutation.addApp(.init("app")),
            .generateEmail,
            .saveWebhook(id: nil, name: "Builds", avatarURL: "")
        ].enumerated() {
            await #expect(throws: (any Error).self) {
                _ = try await harness.call(MutateConversation(
                    mutation: mutation, conversationID: .init("room"),
                    operationID: .init("denied-\(index)"), expectedRevision: nil
                ))
            }
        }
        #expect(await harness.backend.appSearchReads == 0)
        #expect(await harness.backend.emailReads == 0)
        #expect(await harness.backend.appOpens == 0)
        #expect(await harness.backend.managementMutations.isEmpty)
        await harness.service.shutdown()
    }
}
