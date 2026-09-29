import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// The backfill runner (the mentions-list spec §2 and §5), driven through the
/// engine's own event loop: a `gap(.everything)` is a world load, exactly as
/// `LocalBridgeBackend` sends it.
@Suite(.timeLimit(.minutes(1)))
struct MentionBackfillRunTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func conversation(_ id: String, minutesAgo: Double = 1) -> Conversation {
        Conversation(
            id: Conversation.ID(id), kind: .space, lastActivity: now.addingTimeInterval(-minutesAgo * 60)
        )
    }

    private func page(in conversation: Conversation.ID) -> [Message] {
        [Message(
            id: Message.ID("\(conversation.rawValue)|m"), conversationID: conversation,
            threadID: MessageThread.ID("t"), sender: Member.ID("users/alice"), text: "hi",
            createdAt: now.addingTimeInterval(-30)
        )]
    }

    private func makeEngine(
        over backend: GatedHistoryBackend, clocked: Bool = true
    ) async throws -> (SyncEngine, ChatStore) {
        let store = try ChatStore.inMemory()
        let clock = now
        let mentionClock: (@Sendable () -> Date)? = clocked ? { @Sendable in clock } : nil
        let engine = SyncEngine(backend: backend, store: store, mentionClock: mentionClock)
        try await engine.start()
        return (engine, store)
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

    /// For the negative assertions: nothing to wait on, so a fixed settle,
    /// each with a positive control.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    @Test func neverMoreThanThreeFetchesAreInFlight() async throws {
        let world = (1 ... 5).map { conversation("space/\($0)", minutesAgo: Double($0)) }
        let backend = GatedHistoryBackend(world: world)
        let (engine, store) = try await makeEngine(over: backend)
        await backend.emit(.gap(scope: .everything, reason: "test"))
        #expect(await eventually { await backend.parkedCount == 3 })
        await settle()
        #expect(await backend.requested.count == 3)
        await backend.openGate()
        #expect(try await eventually { try store.mentionBackfill() == MentionBackfillStatus() })
        #expect(await backend.requested.count == 5)
        #expect(await backend.maxInFlight == 3)
        await engine.stop()
    }

    /// Review Focus 2, and the reconnect storm (spec §5).
    @Test func aNewWorldLoadCancelsTheOldRunAndTheOldRunWritesNothing() async throws {
        let first = [conversation("space/a"), conversation("space/c", minutesAgo: 2)]
        let backend = GatedHistoryBackend(world: first)
        await backend.answer(Conversation.ID("space/a"), with: page(in: Conversation.ID("space/a")))
        await backend.fail(Conversation.ID("space/c"))
        await backend.answer(Conversation.ID("space/b"), with: page(in: Conversation.ID("space/b")))
        let (engine, store) = try await makeEngine(over: backend)
        await backend.emit(.gap(scope: .everything, reason: "first"))
        #expect(await eventually { await backend.parkedCount == 2 })

        await backend.setWorld([conversation("space/b")])
        await backend.emit(.gap(scope: .everything, reason: "second"))
        #expect(await eventually { await backend.requested.contains(Conversation.ID("space/b")) })

        await backend.release(Conversation.ID("space/a"))
        await backend.release(Conversation.ID("space/c"))
        #expect(await eventually { await backend.inFlight == 1 })
        await settle()
        #expect(try store.messages(in: Conversation.ID("space/a")).isEmpty)
        #expect(try store.mentionBackfill() == MentionBackfillStatus(running: true))

        await backend.release(Conversation.ID("space/b"))
        #expect(try await eventually { try store.mentionBackfill() == MentionBackfillStatus() })
        #expect(try store.messages(in: Conversation.ID("space/b")).count == 1)
        await engine.stop()
    }

    @Test func aFailureIsCountedAndIsNotASessionError() async throws {
        let backend = GatedHistoryBackend(
            world: [conversation("space/a"), conversation("space/b", minutesAgo: 2)]
        )
        await backend.fail(Conversation.ID("space/a"))
        await backend.answer(Conversation.ID("space/b"), with: page(in: Conversation.ID("space/b")))
        await backend.openGate()
        let (engine, store) = try await makeEngine(over: backend)
        await backend.emit(.gap(scope: .everything, reason: "test"))
        #expect(try await eventually {
            try store.mentionBackfill() == MentionBackfillStatus(running: false, failedConversations: 1)
        })
        #expect(try store.lastError() == nil)
        #expect(try store.messages(in: Conversation.ID("space/b")).count == 1)
        await engine.stop()
    }

    /// Sign-out mid-run (spec §5). `stop()` cancels the run, a parked fetch
    /// answering afterwards files nothing, and no further fetch starts.
    @Test func stopCancelsTheRunAndNothingLandsAfterIt() async throws {
        let world = (1 ... 5).map { conversation("space/\($0)", minutesAgo: Double($0)) }
        let backend = GatedHistoryBackend(world: world)
        for item in world {
            await backend.answer(item.id, with: page(in: item.id))
        }
        let (engine, store) = try await makeEngine(over: backend)
        await backend.emit(.gap(scope: .everything, reason: "test"))
        #expect(await eventually { await backend.parkedCount == 3 })
        await engine.stop()
        await backend.openGate()
        await settle()
        #expect(await backend.requested.count == 3)
        for item in world {
            #expect(try store.messages(in: item.id).isEmpty)
        }
        #expect(try store.mentionBackfill() == MentionBackfillStatus(running: true))
        withExtendedLifetime(engine) {}
    }

    /// A world load that lands while `stop()` drains the event loop starts
    /// no run, not even its status write. The world itself still lands: that
    /// is the positive control.
    @Test func aWorldLoadThatLandsDuringStopStartsNoRun() async throws {
        let backend = GatedHistoryBackend(world: [conversation("space/a")])
        await backend.holdWorld()
        let (engine, store) = try await makeEngine(over: backend)
        await backend.emit(.gap(scope: .everything, reason: "test"))
        #expect(await eventually { await backend.isHoldingWorld })
        let stopping = Task { await engine.stop() }
        await settle()
        await backend.releaseWorld()
        await stopping.value
        await settle()
        #expect(try store.conversations().count == 1)
        #expect(try store.mentionBackfill() == MentionBackfillStatus())
        #expect(await backend.requested.isEmpty)
        withExtendedLifetime(engine) {}
    }

    /// Ruling 7: `FakeBackend`'s first connect pushes its world with no gap.
    @Test func aPushedWorldStartsARunToo() async throws {
        let backend = GatedHistoryBackend(world: [])
        await backend.answer(Conversation.ID("space/a"), with: page(in: Conversation.ID("space/a")))
        await backend.openGate()
        let (engine, store) = try await makeEngine(over: backend)
        await backend.emit(.conversationsChanged([conversation("space/a")]))
        #expect(try await eventually { try store.messages(in: Conversation.ID("space/a")).count == 1 })
        await engine.stop()
    }

    /// Ruling 6: an engine built without a clock fetches nothing it did not before.
    @Test func anEngineWithNoClockDoesNotBackfill() async throws {
        let backend = GatedHistoryBackend(world: [conversation("space/a")])
        await backend.openGate()
        let (engine, store) = try await makeEngine(over: backend, clocked: false)
        await backend.emit(.gap(scope: .everything, reason: "test"))
        #expect(try await eventually { try store.conversations().count == 1 })
        await settle()
        #expect(await backend.requested.isEmpty)
        #expect(try store.mentionBackfill() == MentionBackfillStatus())
        await engine.stop()
    }
}
