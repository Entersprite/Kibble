import ChatKit
import Testing
@testable import LocalBridgeBackend

@Suite(.timeLimit(.minutes(1)))
struct SpaceEmailBackendTests {
    @Test func emailGenerationDeliveryAndDeletionUseConfirmedScopedStateAndReplayOnce() async throws {
        let transport = try WebhookTransport()
        await transport.enableEmail()
        let backend = try await connected(transport)
        let room = Conversation.ID("space/a")
        #expect(try await backend.conversationEmail(room).canGenerate)
        let first = try await backend.mutateConversation(
            .generateEmail,
            in: room,
            operationID: "generate",
            expectedRevision: nil
        )
        #expect(try await backend.mutateConversation(
            .generateEmail,
            in: room,
            operationID: "generate",
            expectedRevision: nil
        ) == first)
        let generated = try await backend.conversationEmail(room)
        #expect(generated.address == "room@example.invalid" && generated.deliveryEnabled == true)
        #expect(generated.canDelete && !generated.canGenerate)
        _ = try await backend.mutateConversation(
            .setEmailDelivery(false),
            in: room,
            operationID: "disable",
            expectedRevision: nil
        )
        #expect(try await backend.conversationEmail(room).deliveryEnabled == false)
        _ = try await backend.mutateConversation(
            .deleteEmail,
            in: room,
            operationID: "delete",
            expectedRevision: nil
        )
        #expect(try await backend.conversationEmail(room).address == nil)
        #expect(await transport.writes == 3)
        await backend.disconnect()
    }

    @Test func managerCannotDeleteAndRevocationPreventsAnotherWrite() async throws {
        let transport = try WebhookTransport()
        await transport.enableEmail(owner: false)
        let backend = try await connected(transport)
        let room = Conversation.ID("space/a")
        _ = try await backend.mutateConversation(
            .generateEmail,
            in: room,
            operationID: "generate",
            expectedRevision: nil
        )
        #expect(try await backend.conversationEmail(room).canDelete == false)
        await #expect(throws: ChatError.self) {
            _ = try await backend.mutateConversation(
                .deleteEmail,
                in: room,
                operationID: "delete",
                expectedRevision: nil
            )
        }
        await transport.revoke()
        await #expect(throws: ChatError.self) {
            _ = try await backend.mutateConversation(
                .setEmailDelivery(false),
                in: room,
                operationID: "revoked",
                expectedRevision: nil
            )
        }
        #expect(await transport.writes == 1)
        await backend.disconnect()
    }

    private func connected(_ transport: WebhookTransport) async throws -> LocalBridgeBackend {
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect(); try await SearchBackendSupport.waitForSelf(backend)
        return backend
    }
}
