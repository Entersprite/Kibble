import ChatKit
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ConversationSettingsClientTests {
    @Test func backendWitnessesCrossTheSerializedServiceAndKeepCollidingConversationsAccountScoped(
    ) async throws {
        let harness = try await ClientHarness.make()
        let first: any ChatBackend = harness.backend(harness.first)
        let second: any ChatBackend = harness.backend(harness.second)
        let room = Conversation.ID("same")
        let app = try #require(try await first.searchConversationApps("", in: room).first)
        _ = try await first.mutateConversation(
            .addApp(app.id),
            in: room,
            operationID: "app",
            expectedRevision: nil
        )
        #expect(try await first.conversationIntegrations(room).apps.map(\.id) == [app.id])
        #expect(try await second.conversationIntegrations(room).apps.isEmpty)
        #expect(try await first.openAppConversation(app.id, from: room).kind == .appDirectMessage)
        _ = try await first.mutateConversation(
            .saveWebhook(id: nil, name: "Builds", avatarURL: ""), in: room,
            operationID: "hook", expectedRevision: nil
        )
        let hook = try #require(try await first.conversationIntegrations(room).webhooks.first)
        #expect(try await first.webhookDeliveryURL(hook.id, in: room).host == "example.invalid")
        await #expect(throws: (any Error).self) {
            _ = try await second.webhookDeliveryURL(hook.id, in: room)
        }
        _ = try await first.mutateConversation(
            .generateEmail,
            in: room,
            operationID: "mail",
            expectedRevision: nil
        )
        #expect(try await first.conversationEmail(room).address != nil)
        #expect(try await second.conversationEmail(room).address == nil)
        let patch = ConversationDetailsPatch(
            name: "Renamed",
            description: "Notes",
            guidelines: "Be kind",
            emoji: "🐾"
        )
        _ = try await first.mutateConversation(
            .details(patch),
            in: room,
            operationID: "details",
            expectedRevision: nil
        )
        let details = try await first.conversationDetails(room)
        #expect(details.conversation.title == "Renamed" && details.guidelines == "Be kind")
        #expect(details.settings?.emoji == "🐾")
        #expect(try await second.conversationDetails(room).conversation.title != "Renamed")
        await harness.service.shutdown()
    }
}
