import ChatAPI
import ChatKit
import Foundation
import ServiceClient
import Testing

@Suite(.timeLimit(.minutes(1)))
struct MessagePinIntegrationTests {
    @Test func pinsCrossTheSerializerAndStayAccountScoped() async throws {
        let harness = try await ClientHarness.make()
        let first = harness.backend(harness.first)
        let second = harness.backend(harness.second)
        try await first.connect()
        try await second.connect()
        try await harness.providers.incoming(harness.first.id, count: 1)
        let canonical = try await harness.canonical(harness.first.id)
        try await eventually { try !canonical.recentHistory(in: .init("same"), limit: 1).isEmpty }
        let message = try #require(try canonical.recentHistory(in: .init("same"), limit: 1).first)
        let before = try await first.pinnedMessages(in: .init("same"))
        #expect(before.messages.isEmpty)
        let value = try await first.setMessagePinned(true, at: MessageAddress(
            conversation: message.conversationID, thread: message.threadID, message: message.id
        ))
        #expect(value.messages.map(\.id) == [message.id])
        let read = try await first.pinnedMessages(in: .init("same"))
        #expect(read == value)
        let other = try await second.pinnedMessages(in: .init("same"))
        #expect(other.messages.isEmpty)
        await first.disconnect()
        await second.disconnect()
        await harness.service.shutdown()
    }
}
