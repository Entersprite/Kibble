import ChatKit
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1)))
struct ForegroundRefreshCoalescingTests {
    private let space = Conversation.ID("space/focus")

    @MainActor
    private func eventually(_ condition: () async throws -> Bool) async rethrows -> Bool {
        for _ in 0 ..< 400 {
            if try await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return try await condition()
    }

    @MainActor
    @Test func overlappingFocusReturnsShareOneRefreshAndLaterFocusStillRefreshes() async throws {
        let conversation = Conversation(id: space, kind: .space)
        let backend = GatedHistoryBackend(world: [conversation], needsMentionBackfill: false)
        await backend.openGate()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine)
        try await model.start()
        try store.apply([.replaceConversations([conversation]), .setConnectionState(.connected)])
        #expect(await eventually { model.connectionState == .connected })
        model.select(space)
        #expect(await eventually { await backend.requested.count == 1 })
        await backend.holdWorld()
        model.setActive(false)
        model.setActive(true)
        #expect(await eventually { await backend.isHoldingWorld })
        try #require(model.foregroundRefreshTask != nil)
        model.setActive(false)
        model.setActive(true)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await backend.worldRequests == 1)
        await backend.releaseWorld()
        #expect(await eventually { model.foregroundRefreshTask == nil })
        #expect(await backend.requested.count == 2)
        model.setActive(false)
        model.setActive(true)
        #expect(await eventually { await backend.worldRequests == 2 })
        #expect(await eventually { model.foregroundRefreshTask == nil })
        #expect(await backend.requested.count == 3)
        await model.stop()
    }

    @MainActor
    @Test func aSwitchDuringSharedFocusRefreshReconcilesTheNewSelection() async throws {
        let other = Conversation.ID("space/other")
        let conversations = [Conversation(id: space, kind: .space), Conversation(id: other, kind: .space)]
        let backend = GatedHistoryBackend(world: conversations, needsMentionBackfill: false)
        await backend.openGate()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine)
        try await model.start()
        try store.apply([.replaceConversations(conversations), .setConnectionState(.connected)])
        #expect(await eventually { model.connectionState == .connected })
        model.select(space)
        #expect(await eventually { await backend.requested.count == 1 })
        await backend.holdWorld()
        model.setActive(false)
        model.setActive(true)
        #expect(await eventually { await backend.isHoldingWorld })
        var message = Message(
            id: Message.ID("message/other"), conversationID: other,
            threadID: MessageThread.ID("thread/other"),
            sender: Member.ID("member/other"), text: "before", createdAt: Date(timeIntervalSince1970: 100)
        )
        await backend.answer(other, with: [message])
        model.select(other)
        #expect(await eventually { model.messages.first?.text == "before" })
        message.text = "edited while shared focus refresh waited"
        await backend.answer(other, with: [message])
        model.setActive(false)
        model.setActive(true)
        await backend.releaseWorld()
        #expect(await eventually { model.foregroundRefreshTask == nil })
        #expect(await eventually { model.messages == [message] })
        #expect(await backend.requested.filter { $0 == other }.count == 2)
        await model.stop()
    }

    @MainActor
    @Test func aForegroundWorldAnswerAfterStopCannotRepopulateAnErasedStore() async throws {
        let conversation = Conversation(id: space, kind: .space)
        let backend = GatedHistoryBackend(world: [conversation], needsMentionBackfill: false)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine)
        try await model.start()
        try store.apply([.setConnectionState(.connected)])
        #expect(await eventually { model.connectionState == .connected })
        await backend.holdWorld()
        model.setActive(false)
        model.setActive(true)
        #expect(await eventually { await backend.isHoldingWorld })
        let refresh = try #require(model.foregroundRefreshTask)
        await model.stop()
        try store.erase()
        await backend.releaseWorld()
        await refresh.value
        #expect(try store.conversations().isEmpty)
        #expect(try store.messages(in: space).isEmpty)
        #expect(try store.lastError() == nil)
        #expect(await backend.requested.isEmpty)
    }
}
