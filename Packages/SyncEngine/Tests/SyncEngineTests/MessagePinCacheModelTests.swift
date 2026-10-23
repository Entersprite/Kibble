import ChatKit
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

private actor CachedPinBackend: ChatBackend {
    nonisolated let capabilities = Capabilities(extendedFlags: ["messagePins"])
    nonisolated let events: AsyncStream<ChatEvent>
    let sink: AsyncStream<ChatEvent>.Continuation
    var connected = false
    var held = true
    var failed = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var reads = 0
    var value: PinnedMessages

    init(_ value: PinnedMessages) {
        self.value = value
        (events, sink) = AsyncStream.makeStream()
    }

    func connect() {
        connected = true; sink.yield(.connectionStateChanged(.connected))
    }

    func disconnect() {
        connected = false
    }

    func send(_: ChatCommand) {}
    func setNotificationSetting(_: NotificationLevel, for _: Conversation.ID) {}
    func loadConversations() -> [Conversation] {
        []
    }

    func loadMessages(in _: Conversation.ID, before _: Message.ID?) -> [Message] {
        []
    }

    func pinnedMessages(in _: Conversation.ID) async throws -> PinnedMessages {
        reads += 1
        guard connected else { throw ChatError.notAuthenticated }
        if held {
            await withCheckedContinuation { waiters.append($0) }
        }
        if failed {
            throw ChatError.unknown("Read failed")
        }
        return value
    }

    func release(failing: Bool = false) {
        held = false; failed = failing
        let pending = waiters; waiters = []
        for waiter in pending {
            waiter.resume()
        }
    }

    func replace(_ value: PinnedMessages) {
        self.value = value
        sink.yield(.messagePinsChanged(.init("room")))
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MessagePinCacheModelTests {
    private let room = Conversation.ID("room")
    private var message: Message {
        .init(
            id: .init("saved"),
            conversationID: room,
            threadID: .init("old"),
            sender: .init("peer"),
            text: "Saved pin",
            createdAt: .distantPast
        )
    }

    @Test func selectionBeforeConnectionShowsSavedPinsWithoutMakingAFailingRequest() async throws {
        let harness = try make()
        let store = harness.store; let backend = harness.backend; let model = harness.model
        model.select(room)
        try await wait { model.pins.messages == [message] }
        #expect(await backend.reads == 0)
        #expect(model.pinsError == nil)
        #expect(!model.pins.canModify)
        try await model.start()
        try await wait { await backend.reads > 0 }
        #expect(model.pins.messages == [message])
        #expect(model.pinsError == nil)
        model.refreshPins(); model.refreshPins()
        #expect(await backend.reads == 1)
        await backend.release()
        try await wait { !model.isLoadingPins && model.pins.canModify }
        #expect(model.pins.messages == [message])
        await backend.replace(.init())
        try await wait { !model.isLoadingPins && model.pins.messages.isEmpty }
        #expect(try store.cachedMessagePins(in: room) == PinnedMessages())
        await model.stop()
    }

    @Test func genuineRefreshFailureKeepsTheSavedCollectionAndReportsFailure() async throws {
        let harness = try make()
        let backend = harness.backend; let model = harness.model
        try await model.start(); model.select(room)
        try await wait { await backend.reads > 0 }
        #expect(model.pins.messages == [message])
        await backend.release(failing: true)
        try await wait { !model.isLoadingPins }
        #expect(model.pins.messages == [message])
        #expect(model.pinsError != nil)
        await model.stop()
    }

    private struct Harness {
        let store: ChatStore
        let backend: CachedPinBackend
        let model: ChatSessionModel
    }

    private func make() throws -> Harness {
        let store = try ChatStore.inMemory()
        let value = PinnedMessages(messages: [message], canModify: true)
        try store.apply([
            .upsertConversation(.init(id: room, kind: .space)),
            .replaceMessagePins(conversation: room, pins: value)
        ])
        let backend = CachedPinBackend(value)
        return Harness(
            store: store,
            backend: backend,
            model: ChatSessionModel(
                store: store,
                engine: SyncEngine(backend: backend, store: store)
            )
        )
    }

    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0 ..< 300 {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await condition())
    }
}
