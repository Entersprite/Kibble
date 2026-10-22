import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct ConversationPreviewTests {
    @Test func serializedPreviewDoesNotCreateCanonicalConversationOrHistory() async throws {
        let harness = try await ReconciliationHarness.make()
        let room = Conversation.ID("unjoined")
        let message = Message(
            id: .init("preview"), conversationID: room, threadID: .init("thread"),
            sender: .init("author"), text: "Visible before joining",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let value = ConversationPreview(
            messages: [message],
            members: [Member(id: message.sender, kind: .human)]
        )
        await harness.backend.setPreview(value)
        do {
            #expect(try await harness.call(GetConversationPreview(conversationID: room)) == value)
            #expect(try harness.storage.conversation(room) == nil)
            #expect(try harness.storage.recentHistory(in: room, limit: 100).isEmpty)
            #expect(await harness.backend.sentCommands.isEmpty)
        } catch {
            await harness.service.shutdown()
            throw error
        }
        await harness.service.shutdown()
    }

    @Test func anotherConversationsPreviewCannotIssueMediaAuthority() async throws {
        let harness = try await ReconciliationHarness.make()
        let value = ConversationPreview(messages: [Message(
            id: .init("wrong"), conversationID: .init("other"), threadID: .init("thread"),
            sender: .init("author"), text: "Wrong room", createdAt: Date(timeIntervalSince1970: 100)
        )])
        await harness.backend.setPreview(value)
        await #expect(throws: (any Error).self) {
            _ = try await harness.call(GetConversationPreview(conversationID: .init("unjoined")))
        }
        await harness.service.shutdown()
    }
}
