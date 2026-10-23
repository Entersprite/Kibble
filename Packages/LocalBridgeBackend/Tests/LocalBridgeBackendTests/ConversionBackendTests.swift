import ChatKit
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@Suite(.timeLimit(.minutes(1)))
struct ConversionBackendTests {
    @Test func conversionKeepsIdentityAndRequiresHistoryAcknowledgement() async throws {
        let transport = try WebhookTransport()
        await transport.enableConversion()
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect(); try await SearchBackendSupport.waitForSelf(backend)
        let room = Conversation.ID("space/a")
        #expect(try await backend.conversationDetails(room).conversation.kind == .groupDirectMessage)
        await #expect(throws: ChatError.self) {
            _ = try await backend.mutateConversation(
                .convertToSpace(name: "Planning", emoji: "🐾", acknowledgingHistoryChange: false),
                in: room,
                operationID: "unacknowledged",
                expectedRevision: nil
            )
        }
        #expect(await transport.writes == 0)
        let mutation = ConversationMutation.convertToSpace(
            name: "Planning",
            emoji: "🐾",
            acknowledgingHistoryChange: true
        )
        let result = try await backend.mutateConversation(
            mutation,
            in: room,
            operationID: "convert",
            expectedRevision: nil
        )
        #expect(result.details?.conversation.id == room && result.details?.conversation.kind == .space)
        #expect(result.details?.conversation.title == "Planning" && result.details?.settings?.emoji == "🐾")
        #expect(try await backend.mutateConversation(
            mutation,
            in: room,
            operationID: "convert",
            expectedRevision: nil
        ) == result)
        #expect(await transport.writes == 1)
        await backend.disconnect()
    }

    @Test func conversionRefreshesAGroupFallbackWithoutAdoptingMeetingFacts() throws {
        var group = Group(); group.groupID.spaceID.spaceID = "a"
        group.attributeCheckerGroupType = .flatRoom
        let fallback = Conversation(id: .init("space/a"), kind: .groupDirectMessage, members: [.init("me")])
        let mapped = try #require(ManagementMapping.conversation(group, fallback: fallback))
        #expect(mapped.kind == .space && mapped.members == fallback.members && mapped.meeting == nil)
    }
}
