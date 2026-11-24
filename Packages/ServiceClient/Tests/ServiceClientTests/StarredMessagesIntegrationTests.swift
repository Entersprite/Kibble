import ChatKit
import Foundation
import SyncEngine
import Testing

@Suite(.timeLimit(.minutes(1)))
struct StarredMessagesIntegrationTests {
    @MainActor
    @Test func starsCrossTheSerializerAndStayPrivateToTheSelectedAccount() async throws {
        let harness = try await ClientHarness.make()
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(
            store: store, engine: SyncEngine(backend: harness.backend(harness.first), store: store)
        )
        let second = harness.backend(harness.second)
        try await model.start()
        try await second.connect()
        try await waitFor { model.me == harness.first.selfID && !model.conversations.isEmpty }
        try await harness.providers.incoming(harness.first.id, count: 1)
        try await waitFor { try !store.recentHistory(in: .init("same"), limit: 1).isEmpty }
        let message = try #require(try store.recentHistory(in: .init("same"), limit: 1).first)
        let address = MessageAddress(message)

        model.showStarredMessages()
        try await waitFor { model.stars.showingList && !model.stars.isLoading }
        #expect(model.selected == nil)
        #expect(model.stars.messages.isEmpty)
        #expect(!model.stars.readFailed)

        model.setMessageStarred(true, at: address)
        try await waitFor { model.stars.messages.map(MessageAddress.init) == [address] }
        #expect(model.stars.knownStars.contains(address))
        #expect(try await second.starredMessages(after: nil).messages.isEmpty)

        model.setMessageStarred(false, at: address)
        try await waitFor {
            model.stars.messages.isEmpty && model.stars.pending.isEmpty && !model.stars.isLoading
        }
        #expect(!model.stars.knownStars.contains(address))
        #expect(!model.stars.readFailed)
        await model.stop()
        await second.disconnect()
        await harness.service.shutdown()
    }

    @MainActor
    @Test func anotherClientRefreshesTheOpenListAndTheClosedListKeepsTheExactStarFlag() async throws {
        let harness = try await ClientHarness.make()
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(
            store: store, engine: SyncEngine(backend: harness.backend(harness.first), store: store)
        )
        let other = harness.backend(harness.first)
        try await model.start()
        try await other.connect()
        try await waitFor { model.me == harness.first.selfID }
        let room = Conversation.ID("same")
        try await harness.providers.incoming(harness.first.id, count: 2)
        try await waitFor { try store.recentHistory(in: room, limit: 2).count == 2 }
        let addresses = try store.recentHistory(in: room, limit: 2).map(MessageAddress.init)

        try await other.setMessageStarred(true, at: addresses[0])
        try await waitFor { model.stars.knownStars == [addresses[0]] }
        #expect(!model.stars.showingList)

        model.showStarredMessages()
        try await waitFor { model.stars.messages.map(MessageAddress.init) == [addresses[0]] }
        try await other.setMessageStarred(true, at: addresses[1])
        try await other.setMessageStarred(false, at: addresses[0])
        try await waitFor {
            model.stars.messages.map(MessageAddress.init) == [addresses[1]] && !model.stars.isLoading
        }
        #expect(model.stars.knownStars == [addresses[1]])
        #expect(!model.stars.readFailed)
        await model.stop()
        await other.disconnect()
        await harness.service.shutdown()
    }

    @MainActor
    @Test func aRemoteChangeRefreshesAllLoadedStarredPages() async throws {
        let harness = try await ClientHarness.make()
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(
            store: store, engine: SyncEngine(backend: harness.backend(harness.first), store: store)
        )
        let other = harness.backend(harness.first)
        try await model.start()
        try await other.connect()
        try await waitFor { model.me == harness.first.selfID }
        let room = Conversation.ID("same")
        try await harness.providers.incoming(harness.first.id, count: 33)
        try await waitFor { try store.recentHistory(in: room, limit: 33).count == 33 }
        let addresses = try store.recentHistory(in: room, limit: 33).map(MessageAddress.init)
        let newAddress = try #require(addresses.last)
        for address in addresses.dropLast().reversed() {
            try await other.setMessageStarred(true, at: address)
        }
        try await waitFor { model.stars.knownStars.count == 32 }
        model.showStarredMessages()
        try await waitFor { model.stars.messages.count == 30 && !model.stars.isLoading }
        #expect(model.stars.hasMore)

        model.loadMoreStarredMessages()
        try await waitFor { model.stars.messages.count == 32 && !model.stars.isLoading }
        #expect(!model.stars.hasMore)
        try await other.setMessageStarred(true, at: newAddress)
        try await waitFor {
            model.stars.messages.first.map(MessageAddress.init) == newAddress && !model.stars.isLoading
        }
        #expect(model.stars.messages.map(MessageAddress.init) == [newAddress] + addresses.dropLast())
        #expect(model.stars.knownStars == Set(addresses))
        #expect(!model.stars.hasMore)
        #expect(!model.stars.readFailed)
        await model.stop()
        await other.disconnect()
        await harness.service.shutdown()
    }

    @MainActor
    private func waitFor(_ predicate: @MainActor () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if try predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(try predicate())
    }
}
