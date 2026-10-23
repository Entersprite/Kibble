import ChatKit
import Testing
@testable import FixtureBackend

struct MessagePinTests {
    @Test func collectionIsIndependentOfHistoryAndWritesRequireExactAddress() async throws {
        var world = FixtureWorld.acme
        let message = try #require(world.messages.first { !$0.isDeleted && $0.callStatus == nil })
        world.pinnedMessageIDs = [message.id]
        let backend: any ChatBackend = FakeBackend(world: world, pageSize: 1)
        try await backend.connect()
        let pins = try await backend.pinnedMessages(in: message.conversationID)
        #expect(pins.messages.map(\.id) == [message.id])
        let wrong = MessageAddress(
            conversation: message.conversationID,
            thread: .init("wrong"),
            message: message.id
        )
        await #expect(throws: ChatError.self) { _ = try await backend.setMessagePinned(false, at: wrong) }
        let address = MessageAddress(
            conversation: message.conversationID,
            thread: message.threadID,
            message: message.id
        )
        let removed = try await backend.setMessagePinned(false, at: address)
        #expect(removed.messages.isEmpty)
        let restored = try await backend.setMessagePinned(true, at: address)
        let repeated = try await backend.setMessagePinned(true, at: address)
        #expect(restored == repeated)
    }

    @Test func absentCapabilityRefusesRatherThanReturningEmpty() async throws {
        let backend: any ChatBackend = FakeBackend(capabilities: Capabilities())
        try await backend.connect()
        await #expect(throws: ChatError.self) {
            _ = try await backend.pinnedMessages(in: FixtureWorld.minimal.conversations[0].id)
        }
    }
}
