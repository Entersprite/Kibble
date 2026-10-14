import ChatKit
import Foundation
import Testing
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1)))
struct MentionBackfillReuseTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let first = Conversation.ID("space/a")
    private let second = Conversation.ID("space/b")

    private func conversation(_ id: Conversation.ID, activity: Date? = nil) -> Conversation {
        Conversation(id: id, kind: .space, lastActivity: activity ?? now)
    }

    private func eventually(_ condition: () async throws -> Bool) async rethrows -> Bool {
        for _ in 0 ..< 400 {
            if try await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return try await condition()
    }

    @Test func foregroundRefreshSkipsSuccessfulUnchangedHeadsButLoadsNewAndChangedHeads() async throws {
        let backend = GatedHistoryBackend(world: [conversation(first)])
        await backend.openGate()
        let store = try ChatStore.inMemory()
        let clock = now
        let engine = SyncEngine(backend: backend, store: store, mentionClock: { clock })
        await engine.refreshVisibleConversation(nil)
        #expect(try await eventually {
            let requested = await backend.requested
            return try requested.count == 1 && (store.mentionBackfill()) == MentionBackfillStatus()
        })
        await engine.refreshVisibleConversation(nil)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await backend.requested == [first])
        await backend.setWorld([conversation(first), conversation(second)])
        await engine.refreshVisibleConversation(nil)
        #expect(await eventually { await backend.requested.count == 2 })
        #expect(try await eventually { try store.mentionBackfill() == MentionBackfillStatus() })
        await backend.setWorld([
            conversation(first, activity: now.addingTimeInterval(1)),
            conversation(second)
        ])
        await engine.refreshVisibleConversation(nil)
        #expect(await eventually { await backend.requested.count == 3 })
        #expect(await backend.requested == [first, second, first])
        await engine.stop()
    }

    @Test func anUnchangedWorldDoesNotCancelAndRestartAnInFlightPage() async throws {
        let backend = GatedHistoryBackend(world: [conversation(first)])
        let store = try ChatStore.inMemory()
        let clock = now
        let engine = SyncEngine(backend: backend, store: store, mentionClock: { clock })
        await engine.refreshVisibleConversation(nil)
        #expect(await eventually { await backend.parkedCount == 1 })
        await engine.refreshVisibleConversation(nil)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await backend.parkedCount == 1)
        #expect(await backend.requested == [first])
        await backend.openGate()
        #expect(try await eventually { try store.mentionBackfill() == MentionBackfillStatus() })
        await engine.stop()
    }

    @Test func failedPagesRetryOnTheNextWorldAndRecoveredPagesAreRetained() async throws {
        let backend = GatedHistoryBackend(world: [conversation(first)])
        await backend.fail(first)
        await backend.openGate()
        let store = try ChatStore.inMemory()
        let clock = now
        let engine = SyncEngine(backend: backend, store: store, mentionClock: { clock })
        await engine.refreshVisibleConversation(nil)
        #expect(try await eventually { try store.mentionBackfill().failedConversations == 1 })
        await backend.recover(first)
        await engine.refreshVisibleConversation(nil)
        #expect(await eventually { await backend.requested.count == 2 })
        #expect(try await eventually { try store.mentionBackfill() == MentionBackfillStatus() })
        await engine.refreshVisibleConversation(nil)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await backend.requested.count == 2)
        #expect(try store.lastError() == nil)
        await engine.stop()
    }

    @Test func aRealGapForcesTheUnchangedSuccessfulHeadToReload() async throws {
        let backend = GatedHistoryBackend(world: [conversation(first)])
        await backend.openGate()
        let store = try ChatStore.inMemory()
        let clock = now
        let engine = SyncEngine(backend: backend, store: store, mentionClock: { clock })
        await engine.refreshVisibleConversation(nil)
        #expect(await eventually { await backend.requested.count == 1 })
        #expect(try await eventually { try store.mentionBackfill() == MentionBackfillStatus() })
        await engine.perform(.reloadConversations)
        #expect(await eventually { await backend.requested.count == 2 })
        await engine.stop()
    }

    @Test func visibleHistoryStillReconcilesReactionsEvenWhenHeadIsUnchanged() async throws {
        let backend = GatedHistoryBackend(world: [conversation(first)], needsMentionBackfill: false)
        await backend.openGate()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        var message = Message(
            id: Message.ID("message/a"), conversationID: first, threadID: MessageThread.ID("thread/a"),
            sender: Member.ID("member/a"), text: "hello", createdAt: now
        )
        await backend.answer(first, with: [message])
        await engine.refreshVisibleConversation(first)
        #expect(try store.messages(in: first) == [message])
        message.reactions = [Reaction(emoji: "👍", count: 1)]
        await backend.answer(first, with: [message])
        await engine.refreshVisibleConversation(first)
        #expect(try store.messages(in: first) == [message])
        #expect(await backend.requested.count == 2)
        await engine.stop()
    }
}
