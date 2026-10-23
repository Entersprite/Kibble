import ChatAPI
import ChatKit
import ChatService
import Foundation
import ServiceClient
import SyncEngine
import Testing

@Suite(.timeLimit(.minutes(1)))
struct MessagePinIntegrationTests {
    @MainActor
    @Test func externalPinsReachTheOpenModelThroughTheSerializedServiceAndReplica() async throws {
        let harness = try await ClientHarness.make()
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(
            store: store, engine: SyncEngine(backend: harness.backend(harness.first), store: store)
        )
        try await model.start()
        try await waitForModel("initial snapshot") {
            model.me == harness.first.selfID && !model.conversations.isEmpty
        }
        model.select(.init("same"))
        try await waitForModel("initial pins") { !model.isLoadingPins }
        try await harness.providers.incoming(harness.first.id, count: 1)
        try await waitForModel("history") { try !store.recentHistory(in: .init("same"), limit: 1).isEmpty }
        let message = try #require(try store.recentHistory(in: .init("same"), limit: 1).first)
        let address = MessageAddress(
            conversation: message.conversationID, thread: message.threadID, message: message.id
        )
        try await harness.providers.setPinned(true, account: harness.first.id, address: address)
        try await waitForModel("external pin") { model.pins.messages.map(\.id) == [message.id] }
        #expect(try store.cachedMessagePins(in: message.conversationID)?.messages.map(\.id) == [message.id])
        try await harness.providers.setPinned(false, account: harness.first.id, address: address)
        try await waitForModel("external unpin") { model.pins.messages.isEmpty && !model.isLoadingPins }
        await model.stop()
        await harness.service.shutdown()
    }

    @MainActor
    private func waitForModel(_ stage: String, _ predicate: @MainActor () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if try predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(try predicate(), "Timed out waiting for \(stage)")
    }

    @Test func pinnedImagesDownloadThroughTheirOwnSerializedMediaGrant() async throws {
        let harness = try await ClientHarness.make(uploads: true)
        let attachment = try await DownloadClientTests().issued(harness)
        let canonical = try await harness.canonical(harness.first.id)
        let message = try #require(try canonical.recentHistory(in: .init("same"), limit: 20)
            .first { $0.attachments.contains { $0.id == attachment.id } })
        let backend = harness.backend(harness.first)
        try await backend.connect()
        _ = try await backend.setMessagePinned(true, at: MessageAddress(
            conversation: message.conversationID, thread: message.threadID, message: message.id
        ))
        let pins = try await backend.pinnedMessages(in: message.conversationID)
        let picture = try #require(pins.messages.first?.attachments.first)
        let catalog = try #require(canonical as? any ServiceMediaCatalog)
        let source = try #require(try catalog.mediaSources(for: .attachment(picture.id), at: Date()).first)
        #expect(source.origin == .pinnedMessage(message.conversationID, message.id))
        let bytes = try await backend.attachmentData(picture, size: .preview)
        #expect(bytes.starts(with: Data([137, 80, 78, 71])))
        let foreign = harness.backend(harness.second)
        await #expect(throws: ServiceFailure.notAuthorized) {
            try await foreign.attachmentData(picture, size: .preview)
        }
        await backend.disconnect()
        await foreign.disconnect()
        await harness.service.shutdown()
    }

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
