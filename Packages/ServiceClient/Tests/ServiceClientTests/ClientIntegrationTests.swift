import ChatAPI
import ChatKit
import Foundation
import ServiceClient
import SyncEngine
import Testing

struct ClientIntegrationTests {
    @Test func twoClientsAndCollidingAccountIDsHaveSeparateReplicas() async throws {
        let harness = try await ClientHarness.make()
        let firstStore = try ChatStore.inMemory()
        let mirrorStore = try ChatStore.inMemory()
        let otherStore = try ChatStore.inMemory()
        let first = SyncEngine(backend: harness.backend(harness.first), store: firstStore)
        let mirror = SyncEngine(backend: harness.backend(harness.first), store: mirrorStore)
        let other = SyncEngine(backend: harness.backend(harness.second), store: otherStore)
        try await first.start()
        try await mirror.start()
        try await other.start()
        try await eventually {
            try firstStore.me() == harness.first.selfID && otherStore.me() == harness.second.selfID
        }
        try await harness.providers.incoming(harness.first.id, count: 1)
        try await eventually {
            try firstStore.messages(in: Conversation.ID("same")).count == 1 && mirrorStore
                .messages(in: Conversation.ID("same")).count == 1
        }
        #expect(try otherStore.messages(in: Conversation.ID("same")).isEmpty)
        #expect(try firstStore.replicaCheckpoint()?.account == harness.first.id.rawValue)
        await first.stop()
        try await harness.providers.incoming(harness.first.id, count: 1)
        try await eventually { try mirrorStore.messages(in: Conversation.ID("same")).count == 2 }
        #expect(await harness.service.activeRuntimeCount == 2)
        await mirror.stop()
        await other.stop()
        await harness.service.shutdown()
    }

    @Test func duplicateSendOperationDoesNotPostTwice() async throws {
        let harness = try await ClientHarness.make()
        let backend = harness.backend(harness.first)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        try await engine.start()
        try await eventually { try store.me() == harness.first.selfID }
        let command = ChatCommand.sendMessage(
            conversationID: Conversation.ID("same"),
            threadID: nil,
            text: "One send",
            localID: "stable"
        )
        try await backend.send(command)
        try await backend.send(command)
        try await eventually { try store.messages(in: Conversation.ID("same")).count == 1 }
        #expect(try await backend.loadMessages(in: Conversation.ID("same"), before: nil).count == 1)
        await engine.stop()
        await harness.service.shutdown()
    }

    @Test func reconnectResumesAfterCommittedCursorWithoutFreshArrivalAnnouncements() async throws {
        let harness = try await ClientHarness.make()
        let store = try ChatStore.inMemory()
        let first = SyncEngine(backend: harness.backend(harness.first), store: store)
        try await first.start()
        try await eventually { try store.me() == harness.first.selfID }
        await first.stop()
        try await harness.providers.incoming(harness.first.id, count: 1)
        let resumed = SyncEngine(backend: harness.backend(harness.first), store: store)
        let log = AnnouncementLog()
        let announcements = resumed.announcements
        let observer = Task { for await announcement in announcements {
            await log.append(announcement)
        } }
        try await resumed.start()
        try await eventually { try store.messages(in: Conversation.ID("same")).count == 1 }
        #expect(await log.arrivals.isEmpty)
        #expect(try store.conversations().first?.hasUnread == true)
        await resumed.stop()
        observer.cancel()
        await observer.value
        await harness.service.shutdown()
    }

    @Test func burstOverflowRecoversEveryDurableEvent() async throws {
        let harness = try await ClientHarness.make()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: harness.backend(harness.first), store: store)
        try await engine.start()
        try await eventually { try store.me() == harness.first.selfID }
        try await harness.providers.incoming(harness.first.id, count: 40)
        try await eventually { try store.messages(in: Conversation.ID("same")).count == 40 }
        await engine.stop()
        await harness.service.shutdown()
    }
}
