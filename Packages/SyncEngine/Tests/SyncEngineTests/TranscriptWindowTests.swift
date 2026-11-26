import ChatKit
import FixtureBackend
import Foundation
import GRDB
import Testing
@testable import ChatPersistence
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1)))
struct TranscriptWindowTests {
    let conversation = Conversation.ID("window-chat")

    func message(_ index: Int, date: Date? = nil) -> Message {
        Message(
            id: Message.ID(String(format: "m-%04d", index)), conversationID: conversation,
            threadID: MessageThread.ID("thread-\(index)"), sender: Member.ID("sender"),
            text: "Message \(index)", createdAt: date ?? Date(timeIntervalSince1970: Double(index))
        )
    }

    @Test func recentWindowNeverDecodesOldHistoryAndKeepsItDurable() async throws {
        let store = try ChatStore.inMemory()
        try store.apply((0 ..< 1000).map { .upsertMessage(message($0)) })
        // Invalid old wire data is a positive control: fetching/decode of all
        // history would throw even if presentation subsequently took suffix100.
        try await store.database.write { db in
            try db.execute(sql: "UPDATE message SET reactions = 'invalid' WHERE createdAt < 900")
        }
        let window = try await store.transcriptWindow(in: conversation, request: .latest(100))
        #expect(window.messages.count == 100)
        #expect(window.messages.first?.id == message(900).id)
        #expect(window.messages.last?.id == message(999).id)
        #expect(window.hasOlder)
        #expect(!window.hasNewer)
        let count = try await store.database.read { db in try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM message"
        ) }
        #expect(count == 1000)
    }

    @Test func targetAndBothDirectionsAreBoundedAndTieOrderingIsStable() async throws {
        let store = try ChatStore.inMemory()
        let sharedDate = Date(timeIntervalSince1970: 100)
        try store.apply((0 ..< 1000).map { .upsertMessage(message($0, date: sharedDate)) })
        let target = try await store.transcriptWindow(
            in: conversation,
            request: .around(message(500).id, 100)
        )
        #expect(target.messages.count == 100)
        #expect(target.messages.contains { $0.id == message(500).id })
        #expect(target.hasOlder && target.hasNewer)
        let older = try await store.transcriptWindow(
            in: conversation, request: .ending(TranscriptCursor(#require(target.messages.last)), 500)
        )
        #expect(older.messages.count == 500)
        #expect(older.messages.last?.id == target.messages.last?.id)
        let newer = try await store.transcriptWindow(
            in: conversation, request: .starting(TranscriptCursor(#require(older.messages.first)), 10000)
        )
        #expect(newer.messages.count == 500)
        #expect(newer.messages.first?.id == older.messages.first?.id)
    }

    @Test func decodedCacheUsesCompleteRowsAndEvictsWithinBudget() throws {
        let cache = DecodedTranscriptCache(budget: 10000, entryLimit: 2)
        var original = message(1)
        #expect(try cache.decode(MessageRow(original)) == original)
        original.text = "Edited text"
        #expect(try cache.decode(MessageRow(original)) == original)
        original.reactions = [Reaction(emoji: "👍", count: 2, includesMe: false)]
        #expect(try cache.decode(MessageRow(original)) == original)
        original.isDeleted = true
        #expect(try cache.decode(MessageRow(original)) == original)
        _ = try cache.decode(MessageRow(message(2)))
        _ = try cache.decode(MessageRow(original))
        _ = try cache.decode(MessageRow(message(3)))
        #expect(cache.contains(original.id))
        #expect(!cache.contains(message(2).id))
        #expect(cache.retainedCount <= 2)
        cache.removeAll()
        #expect(cache.retainedCount == 0)
    }

    @MainActor
    @Test func modelPagesBothDirectionsAndOldTargetsNeverPresentNewestAsRead() async throws {
        let store = try ChatStore.inMemory()
        try store.apply((0 ..< 1000).map { .upsertMessage(message($0)) })
        let backend = RecordingBackend(world: .minimal)
        await backend.answerHistory(in: conversation, with: (900 ..< 1000).map { message($0) })
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine)
        model.select(conversation)
        try await wait { model.messages.count == 100 }
        #expect(model.messages.first?.id == message(900).id)
        for expected in stride(from: 200, through: 500, by: 100) {
            let start = 1000 - expected
            await backend.answerHistory(in: conversation, with: (start ..< start + 100).map { message($0) })
            model.loadOlderMessages()
            try await wait { model.messages.count == expected && !model.isLoadingOlderMessages }
        }
        await backend.answerHistory(in: conversation, with: (400 ..< 500).map { message($0) })
        model.loadOlderMessages()
        try await wait { model.messages.first?.id == message(400).id && !model.isLoadingOlderMessages }
        #expect(model.messages.count == 500)
        #expect(model.hasNewerMessages)
        #expect(!model.transcriptIncludesLatest)
        model.loadNewerMessages()
        try await wait { model.messages.last?.id == message(999).id && !model.isLoadingNewerMessages }
        #expect(model.messages.count == 500)
        model.scrollTarget = message(100).id
        try await wait { model.messages.contains { $0.id == message(100).id } && model.messages.count == 100 }
        #expect(model.hasNewerMessages)
        #expect(!model.transcriptIncludesLatest)
        await model.stop()
        #expect(store.decodedTranscriptCache.retainedCount == 0)
    }

    @MainActor
    @Test func olderNetworkFailureAllowsRetryAndEmptySuccessDoesNotTrimCurrentWindow() async throws {
        let store = try ChatStore.inMemory()
        try store.apply((100 ..< 200).map { .upsertMessage(message($0)) })
        let backend = RecordingBackend(world: .minimal)
        await backend.failHistory(true)
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine)
        model.select(conversation)
        try await wait { model.messages.count == 100 }
        model.loadOlderMessages()
        try await wait { !model.isLoadingOlderMessages }
        #expect(model.hasOlderMessages)
        #expect(!model.transcriptWork.serverExhausted)
        await backend.failHistory(false)
        await backend.answerHistory(in: conversation, with: (0 ..< 100).map { message($0) })
        model.loadOlderMessages()
        try await wait { model.messages.count == 200 && !model.isLoadingOlderMessages }
        #expect(model.messages.first?.id == message(0).id)
        await backend.answerHistory(in: conversation, with: [])
        model.loadOlderMessages()
        try await wait { !model.isLoadingOlderMessages }
        #expect(!model.hasOlderMessages)
        #expect(model.messages.count == 200)
        await model.stop()
    }

    @MainActor
    @Test func shortServerPageCannotJumpToDisconnectedCachedSearchContext() async throws {
        let store = try ChatStore.inMemory()
        let newest = (1000 ..< 1100).map { message($0) }
        try store.apply(((0 ..< 50).map { message($0) } + newest).map { .upsertMessage($0) })
        let backend = RecordingBackend(world: .minimal)
        await backend.answerHistory(in: conversation, with: newest)
        let model = ChatSessionModel(store: store, engine: SyncEngine(backend: backend, store: store))
        model.select(conversation)
        try await wait { model.messages.count == 100 }
        await backend.answerHistory(in: conversation, with: (990 ..< 1000).map { message($0) })
        model.loadOlderMessages()
        try await wait { model.messages.count == 110 && !model.isLoadingOlderMessages }
        #expect(model.messages.first?.id == message(990).id)
        #expect(!model.messages.contains { $0.createdAt < message(990).createdAt })
        await backend.answerHistory(in: conversation, with: [])
        model.loadOlderMessages()
        try await wait { !model.isLoadingOlderMessages }
        #expect(model.messages.count == 110)
        #expect(model.hasOlderMessages)
        #expect(!model.transcriptWork.serverExhausted)
        #expect(try store.messages(in: conversation).count == 160)
        try store.apply([.removeMessage(id: message(990).id)])
        try await wait { model.messages.count == 109 }
        #expect(model.messages.first?.id == message(991).id)
        await model.stop()
    }

    @MainActor
    @Test func openingAnOldTargetBeforeSelectionObservationDoesNotScheduleAReadMark() async throws {
        let store = try ChatStore.inMemory()
        try store.apply((0 ..< 1000).map { .upsertMessage(message($0)) })
        let backend = RecordingBackend(world: .minimal)
        await backend.answerHistory(in: conversation, with: [])
        let model = ChatSessionModel(
            store: store,
            engine: SyncEngine(backend: backend, store: store),
            markReadDebounce: .zero
        )
        model.select(conversation)
        model.scrollTarget = message(100).id
        try await wait { model.messages.contains { $0.id == message(100).id } }
        #expect(!model.transcriptIncludesLatest)
        #expect(model.markTasks.isEmpty)
        let marks = await backend.commands.filter {
            if case .markRead = $0 {
                return true
            }
            return false
        }
        #expect(marks.isEmpty)
        await model.stop()
    }

    @MainActor
    @Test func anOfflineTargetOnlyCacheCannotMarkReadAndOffersLatestRetry() async throws {
        let store = try ChatStore.inMemory()
        try store.apply((50 ..< 150).map { .upsertMessage(message($0)) })
        let backend = RecordingBackend(world: .minimal)
        await backend.failHistory(true)
        let model = ChatSessionModel(
            store: store,
            engine: SyncEngine(backend: backend, store: store),
            markReadDebounce: .zero
        )
        model.conversations = [Conversation(
            id: conversation,
            kind: .space,
            unreadCount: 10,
            readPosition: Date(timeIntervalSince1970: 0)
        )]
        model.select(conversation)
        model.scrollTarget = message(100).id
        try await wait { model.messages.contains { $0.id == message(100).id } }
        #expect(!model.transcriptIncludesLatest)
        #expect(model.hasNewerMessages)
        model.markSelectedReadIfNeeded()
        #expect(model.markTasks.isEmpty)
        model.loadNewerMessages()
        try await wait { !model.isLoadingNewerMessages }
        #expect(!model.transcriptIncludesLatest)
        #expect(model.hasNewerMessages)
        #expect(model.markTasks.isEmpty)
        await backend.failHistory(false)
        await backend.answerHistory(in: conversation, with: (1000 ..< 1100).map { message($0) })
        model.loadNewerMessages()
        try await wait { model.messages.last?.id == message(1099).id && !model.isLoadingNewerMessages }
        #expect(model.transcriptIncludesLatest)
        #expect(model.scrollTarget == nil)
        await model.stop()
    }

    @MainActor
    @Test func disjointSearchContextOffersExplicitLatestJumpAndKeepsReadIneligibleUntilJump() async throws {
        let store = try ChatStore.inMemory()
        let context = (50 ..< 150).map { message($0) }
        let newest = (1000 ..< 1100).map { message($0) }
        try store.apply((context + newest).map { .upsertMessage($0) })
        let backend = RecordingBackend(world: .minimal)
        await backend.answerHistory(in: conversation, with: newest)
        let model = ChatSessionModel(
            store: store,
            engine: SyncEngine(backend: backend, store: store),
            markReadDebounce: .zero
        )
        model.select(conversation)
        model.scrollTarget = message(100).id
        try await wait { model.messages.contains { $0.id == message(100).id } }
        #expect(model.newerMessagesAreLatestJump)
        #expect(!model.transcriptIncludesLatest)
        #expect(model.messages.allSatisfy { $0.createdAt <= message(149).createdAt })
        #expect(model.markTasks.isEmpty)
        model.loadNewerMessages()
        try await wait { model.messages.last?.id == message(1099).id && !model.isLoadingNewerMessages }
        #expect(model.messages.first?.id == message(1000).id)
        #expect(!model.newerMessagesAreLatestJump)
        #expect(model.transcriptIncludesLatest)
        await model.stop()
    }

    @MainActor
    @Test func unchangedLatestConfirmationReanchorsTargetAndKeepsFollowingArrivals() async throws {
        let store = try ChatStore.inMemory()
        let initial = (0 ..< 100).map { message($0) }
        try store.apply(initial.map { .upsertMessage($0) })
        let backend = RecordingBackend(world: .minimal)
        await backend.holdHistory(true)
        await backend.answerHistory(in: conversation, with: initial)
        let model = ChatSessionModel(store: store, engine: SyncEngine(backend: backend, store: store))
        model.select(conversation)
        model.scrollTarget = message(90).id
        try await wait { model.messages.contains { $0.id == message(99).id } }
        #expect(!model.transcriptIncludesLatest)
        var held = await backend.abortableHistory.count
        for _ in 0 ..< 10000 where held == 0 {
            await Task.yield()
            held = await backend.abortableHistory.count
        }
        try #require(held == 1)
        await backend.abortableHistory.release()
        try await wait { model.transcriptIncludesLatest && !model.transcriptWork.isTargeted }
        try store.apply((100 ..< 250).map { .upsertMessage(message($0)) })
        try await wait { model.messages.last?.id == message(249).id }
        #expect(model.messages.count == 100)
        #expect(!model.newerMessagesAreLatestJump)
        await model.stop()
    }

    @Test func yearsSpanningCachedRootVerificationDecodesOnlySixEligibleCandidates() async throws {
        let store = try ChatStore.inMemory()
        try store.apply((0 ..< 10000).map { .upsertMessage(message($0)) })
        // The API's recently active roots can span all cached history. Rows
        // below the six eligible candidates must never be decoded here.
        try await store.database.write { db in
            try db.execute(sql: "UPDATE message SET reactions = 'invalid' WHERE createdAt < 9992")
        }
        let excluded = Set((0 ..< 9992).map { message($0).id } + [message(9998).id, message(9999).id])
        let candidates = try store.cachedMissingRootCandidates(
            in: conversation, from: message(0).createdAt, through: message(9999).createdAt,
            excluding: excluded
        )
        #expect(candidates.map(\.id) == (9992 ..< 9998).map { message($0).id })
        #expect(store.decodedTranscriptCache.retainedCount == 6)
    }

    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 10000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        #expect(condition())
        try #require(condition())
    }
}
