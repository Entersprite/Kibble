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
        for _ in 0 ..< 2000 where model.isLoadingPins {
            await Task.yield()
        }
        #expect(model.pins.canModify)
        model.setPinned(true, message: message)
        #expect(model.pins.messages.map(\.id) == [message.id])
        for _ in 0 ..< 2000 where model.isLoadingPins {
            await Task.yield()
        }
        #expect(!model.isLoadingPins)
        #expect(model.pins.messages.map(\.id) == [message.id])
        model.select(other.id)
        #expect(model.pins.messages.isEmpty)
        for _ in 0 ..< 2000 where model.isLoadingPins {
            await Task.yield()
        }
        #expect(model.pins.messages.isEmpty)
        await model.stop()
        #expect(model.pins.messages.isEmpty)
    }
}
