import ChatKit
import Foundation
import GRDB
import Testing
@testable import ChatPersistence
@testable import SyncEngine

/// A chat whose history confidence has moved opens on its saved rows, marked
/// unconfirmed, until its newest page confirms what the service still has.
@Suite(.timeLimit(.minutes(1)))
struct SavedTranscriptTests {
    let conversation = Conversation.ID("saved-chat")
    let topic = MessageThread.ID("topic")

    func message(_ index: Int, in chat: Conversation.ID? = nil) -> Message {
        Message(
            id: Message.ID("row-\(index)"), conversationID: chat ?? conversation, threadID: topic,
            sender: Member.ID("other"), text: "message \(index)",
            createdAt: Date(timeIntervalSince1970: Double(index))
        )
    }

    /// Two saved roots, then history confidence moves.
    func invalidated() throws -> ChatStore {
        let store = try ChatStore.inMemory()
        try store.apply([
            .replaceConversations([Conversation(id: conversation, kind: .space)]),
            .upsertMessage(message(1)), .upsertMessage(message(4))
        ])
        try store.apply([.invalidateReplicaHistory])
        return store
    }

    // MARK: - The store

    @Test func aChatWithNothingConfirmedShowsItsSavedRows() async throws {
        let store = try invalidated()
        #expect(try await store.transcriptWindow(in: conversation, request: .latest(100)).messages.isEmpty)
        let window = try await store.transcriptWindow(
            in: conversation, request: .latest(100), includingUnconfirmed: true
        )
        #expect(window.messages.map(\.id) == [message(1).id, message(4).id])
        #expect(window.unconfirmed == [message(1).id, message(4).id])
    }

    /// The newest page landing is what switches the window: no new request.
    @Test func oneConfirmedRowSwitchesTheWindowToConfirmedOnly() async throws {
        let store = try invalidated()
        try store.apply([.upsertMessage(message(5))])
        let window = try await store.transcriptWindow(
            in: conversation, request: .latest(100), includingUnconfirmed: true
        )
        #expect(window.messages.map(\.id) == [message(5).id])
        #expect(window.unconfirmed.isEmpty)
    }

    /// Neither a tracked delivery nor an untracked local row confirms the chat.
    @Test(arguments: [true, false])
    func aPendingSendDoesNotHideTheSavedCopy(tracked: Bool) async throws {
        let store = try invalidated()
        var pending = message(6)
        pending.id = tracked ? Message.ID("row-6") : Message.ID("local/pending")
        pending.localID = "operation-6"
        try store.apply([.upsertMessage(pending)] + (tracked ? [.beginMessageDelivery(pending.id)] : []))
        let window = try await store.transcriptWindow(
            in: conversation, request: .latest(100), includingUnconfirmed: true
        )
        #expect(window.messages.map(\.id) == [message(1).id, message(4).id, pending.id])
        #expect(window.unconfirmed.isSuperset(of: [message(1).id, message(4).id]))
    }

    @Test func aChatNeverInvalidatedReadsTheSameEitherWay() async throws {
        let store = try ChatStore.inMemory()
        try store.apply([
            .replaceConversations([Conversation(id: conversation, kind: .space)]),
            .upsertMessage(message(1)), .upsertMessage(message(4))
        ])
        let confirmed = try await store.transcriptWindow(in: conversation, request: .latest(100))
        let saved = try await store.transcriptWindow(
            in: conversation, request: .latest(100), includingUnconfirmed: true
        )
        #expect(saved == confirmed)
        #expect(saved.messages.count == 2)
    }

    @Test func aMeetingSeriesShowsItsSavedRowsToo() async throws {
        let store = try invalidated()
        let window = try await store.meetingTranscript(
            occurrences: [conversation], request: .latest(100), includingUnconfirmed: true
        )
        #expect(window.messages.map(\.id) == [message(1).id, message(4).id])
        #expect(window.unconfirmed == [message(1).id, message(4).id])
        try store.apply([.upsertMessage(message(5))])
        let confirmed = try await store.meetingTranscript(
            occurrences: [conversation], request: .latest(100), includingUnconfirmed: true
        )
        #expect(confirmed.messages.map(\.id) == [message(5).id])
        #expect(confirmed.unconfirmed.isEmpty)
    }

    @Test func savedWindowsStayCheapAtRealisticSize() async throws {
        let store = try ChatStore.inMemory()
        try store.apply((0 ..< 10000).map { .upsertMessage(message($0)) })
        try store.apply([.invalidateReplicaHistory])
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0 ..< 20 {
            let window = try await store.transcriptWindow(
                in: conversation, request: .latest(100), includingUnconfirmed: true
            )
            #expect(window.messages.count == 100)
            #expect(window.unconfirmed.count == 100)
        }
        #expect(start.duration(to: clock.now) < .seconds(5))
        print("Saved history, 10k unconfirmed, 20 windows: \(start.duration(to: clock.now))")
    }

    // MARK: - The model

    @MainActor
    @Test func aChatOpensOnItsSavedCopyAndTheNewestPageReplacesIt() async throws {
        let setup = try await started()
        let (model, backend, sink) = (setup.model, setup.backend, setup.sink)
        model.select(conversation)
        for _ in 0 ..< 500 where model.messages.isEmpty {
            await Task.yield()
        }
        #expect(model.messages.map(\.id) == [message(1).id, message(4).id])
        #expect(model.unconfirmedMessageIDs == [message(1).id, message(4).id])
        #expect(model.isLoadingLatestMessages)
        #expect(!model.hasOlderMessages)
        // Nothing is marked read from rows the service has not confirmed.
        #expect(sink.triggers.isEmpty)

        // Message 1 was deleted while away; 5 is new. The gate stays open:
        // this backend is not the service, so the engine then checks the
        // missing saved root with a fetch of its own.
        await backend.answer(conversation, with: [message(4), message(5)])
        await backend.openGate()
        for _ in 0 ..< 500 where !model.unconfirmedMessageIDs.isEmpty || model.isLoadingLatestMessages {
            await Task.yield()
        }
        #expect(model.messages.map(\.id) == [message(4).id, message(5).id])
        // The fetch still checks missing saved roots after its rows land.
        for _ in 0 ..< 5000 where model.isLoadingLatestMessages {
            await Task.yield()
        }
        #expect(!model.isLoadingLatestMessages)
        for _ in 0 ..< 500 where sink.triggers.isEmpty {
            await Task.yield()
        }
        #expect(!sink.triggers.isEmpty)
        await model.stop()
    }

    @MainActor
    @Test func aFailedPageLeavesTheSavedCopyUp() async throws {
        let setup = try await started()
        let (model, backend) = (setup.model, setup.backend)
        await backend.fail(conversation)
        model.select(conversation)
        for _ in 0 ..< 500 where model.messages.isEmpty {
            await Task.yield()
        }
        await backend.release(conversation)
        for _ in 0 ..< 500 where model.isLoadingLatestMessages {
            await Task.yield()
        }
        #expect(!model.isLoadingLatestMessages)
        #expect(model.messages.map(\.id) == [message(1).id, message(4).id])
        #expect(model.unconfirmedMessageIDs == [message(1).id, message(4).id])
        await model.stop()
    }

    /// A page with nothing in it confirms nothing, so the saved rows would
    /// otherwise stay up for good: the chat is empty now.
    @MainActor
    @Test func anEmptyPageClearsTheSavedCopy() async throws {
        let setup = try await started()
        let (model, backend) = (setup.model, setup.backend)
        model.select(conversation)
        for _ in 0 ..< 500 where model.messages.isEmpty {
            await Task.yield()
        }
        await backend.answer(conversation, with: [])
        await backend.release(conversation)
        for _ in 0 ..< 500 where !model.messages.isEmpty || model.isLoadingLatestMessages {
            await Task.yield()
        }
        #expect(model.messages.isEmpty)
        #expect(model.unconfirmedMessageIDs.isEmpty)
        await model.stop()
    }

    /// Reconnect catch-up replaces the open chat's fetch with its own, and the
    /// replaced fetch must not leave the transcript saying it is loading.
    @MainActor
    @Test func aCatchUpReplacingTheFetchStillEndsLoading() async throws {
        let setup = try await started()
        let (model, backend) = (setup.model, setup.backend)
        model.select(conversation)
        for _ in 0 ..< 500 where await backend.parkedCount == 0 {
            await Task.yield()
        }
        #expect(model.isLoadingLatestMessages)
        await backend.emit(.connectionStateChanged(.connected))
        for _ in 0 ..< 500 where await backend.parkedCount < 2 {
            await Task.yield()
        }
        #expect(await backend.parkedCount == 2)
        await backend.answer(conversation, with: [message(4), message(5)])
        await backend.openGate()
        for _ in 0 ..< 5000 where model.isLoadingLatestMessages {
            await Task.yield()
        }
        #expect(!model.isLoadingLatestMessages)
        await model.stop()
    }

    struct Started {
        let model: ChatSessionModel
        let backend: GatedHistoryBackend
        let sink: FakeMarkReadTraceSink
    }

    @MainActor
    private func started() async throws -> Started {
        let store = try invalidated()
        let backend = GatedHistoryBackend(
            world: [Conversation(id: conversation, kind: .space)], needsMentionBackfill: false
        )
        let sink = FakeMarkReadTraceSink()
        let model = ChatSessionModel(
            store: store, engine: SyncEngine(backend: backend, store: store),
            markReadTrace: sink, markReadDebounce: .zero
        )
        try await model.start()
        for _ in 0 ..< 500 where model.conversations.isEmpty {
            await Task.yield()
        }
        #expect(!model.conversations.isEmpty)
        return Started(model: model, backend: backend, sink: sink)
    }
}
