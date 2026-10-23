import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MessagePinModelTests {
    @Test func pinningIsImmediateAndChangingSelectionClearsTheOldCollection() async throws {
        var world = FixtureWorld.acme
        world.pinnedMessageIDs = []
        let message = try #require(world.messages.first { !$0.isDeleted && $0.callStatus == nil })
        let other = try #require(world.conversations.first { $0.id != message.conversationID })
        let backend = FakeBackend(world: world)
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(store: store, engine: SyncEngine(backend: backend, store: store))
        try await model.start()
        model.select(message.conversationID)
        try await wait { !model.isLoadingPins }
        #expect(model.pins.canModify)
        model.setPinned(true, message: message)
        #expect(model.pins.messages.map(\.id) == [message.id])
        try await wait { !model.isLoadingPins }
        #expect(!model.isLoadingPins)
        #expect(model.pins.messages.map(\.id) == [message.id])
        model.select(other.id)
        #expect(model.pins.messages.isEmpty)
        try await wait { !model.isLoadingPins }
        #expect(model.pins.messages.isEmpty)
        await model.stop()
        #expect(model.pins.messages.isEmpty)
    }

    @Test func anotherClientPinAndUnpinRefreshTheOpenCollectionThroughCommittedEvents() async throws {
        var world = FixtureWorld.acme; world.pinnedMessageIDs = []
        let message = try #require(world.messages.first { !$0.isDeleted && $0.callStatus == nil })
        let backend = FakeBackend(world: world)
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(store: store, engine: SyncEngine(backend: backend, store: store))
        try await model.start(); model.select(message.conversationID)
        try await wait { !model.isLoadingPins }
        let address = MessageAddress(
            conversation: message.conversationID,
            thread: message.threadID,
            message: message.id
        )
        _ = try await backend.setMessagePinned(true, at: address)
        try await wait { model.pins.messages.contains { $0.id == message.id } }
        _ = try await backend.setMessagePinned(false, at: address)
        try await wait { model.pins.messages.isEmpty && !model.isLoadingPins }
        await model.stop()
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}
