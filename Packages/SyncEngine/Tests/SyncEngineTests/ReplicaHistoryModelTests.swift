import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1)))
struct ReplicaHistoryModelTests {
    @MainActor
    @Test func replacementRefreshesSelectedChatAndOpenThreadThroughBackend() async throws {
        let fixture = ReplicaHistoryTests()
        let backend = RecordingBackend(world: .minimal)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine)
        try await model.start()
        try await wait { !model.conversations.isEmpty }
        let conversation = Conversation(id: fixture.conversation, kind: .space, repliesEnabled: true)
        try store.apply([.upsertConversation(conversation)])
        await backend.answerHistory(in: fixture.conversation, with: [fixture.message(1)])
        await backend.answerThread(fixture.topic, with: [fixture.message(1), fixture.message(2, reply: true)])
        model.select(fixture.conversation)
        model.openThread(fixture.topic)
        try await wait { model.messages.contains { $0.id == fixture.message(1).id }
            && model.threads.messages.count == 2
        }
        let before = await backend.loadMessagesCount
        let threadBefore = await backend.threadLoads.count
        let generation = model.transcriptWork.generation
        await backend.answerHistory(in: fixture.conversation, with: [fixture.message(3)])
        await backend.answerThread(fixture.topic, with: [fixture.message(1), fixture.message(4, reply: true)])
        let replacement = ChatDelivery(
            checkpoint: ReplicaCheckpoint(account: "account", stream: "replacement", sequence: 1),
            events: [], isSnapshot: true, isLive: false
        )
        #expect(await engine.handleDelivery(replacement))
        try await wait { model.messages.contains { $0.id == fixture.message(3).id }
            && model.threads.messages.contains { $0.id == fixture.message(4).id }
        }
        #expect(await backend.loadMessagesCount > before)
        #expect(await backend.threadLoads.count > threadBefore)
        #expect(model.transcriptWork.generation > generation)
        #expect(model.selected == fixture.conversation)
        #expect(model.threads.openThread == fixture.topic)
        #expect(!model.threads.messages.contains { $0.id == fixture.message(2).id })
        #expect(try store.message(fixture.message(2).id) == nil)
        await model.stop()
    }

    @MainActor
    @Test func resetCancelsPreviouslyHeldHistoryAndDoesNotAcceptItsLateAnswer() async throws {
        let fixture = ReplicaHistoryTests()
        let backend = RecordingBackend(world: .minimal)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine)
        try await model.start()
        try await wait { !model.conversations.isEmpty }
        try store.apply([.upsertConversation(Conversation(id: fixture.conversation, kind: .space))])
        await backend.answerHistory(in: fixture.conversation, with: [fixture.message(1)])
        await backend.holdHistory(true)
        model.select(fixture.conversation)
        try await wait { await backend.abortableHistory.count == 1 }
        let replacement = ChatDelivery(
            checkpoint: ReplicaCheckpoint(account: "account", stream: "replacement", sequence: 1),
            events: [], isSnapshot: true, isLive: false
        )
        #expect(await engine.handleDelivery(replacement))
        try await wait { await backend.abortableHistory.aborted == 1 }
        try await wait { await backend.abortableHistory.count == 1 }
        #expect(try store.message(fixture.message(1).id) == nil)
        await backend.answerHistory(in: fixture.conversation, with: [fixture.message(3)])
        await backend.holdHistory(false)
        await backend.abortableHistory.release()
        try await wait { model.messages.map(\.id) == [fixture.message(3).id] }
        #expect(try store.message(fixture.message(1).id) == nil)
        await model.stop()
    }

    @MainActor
    private func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0 ..< 2000 {
            if try await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(try await condition())
        throw ChatError.transport("Replica history handoff did not complete.")
    }
}
