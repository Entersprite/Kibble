import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// `ChatSessionModel.stopAndEraseStore()`, and the one guarantee
/// `AppEnvironment.signOut()` and `enterNeedsSignIn()` both depend on: by the
/// time it returns, the sync loop has been fully drained *and* the tables
/// are empty - never the second without the first, and never a write still
/// in flight from this very session landing afterward and repopulating a
/// database that looks erased.
@Suite(.timeLimit(.minutes(1)))
struct ChatSessionModelTeardownTests {
    /// What a caller can actually observe of that guarantee: seed the store
    /// from a running session, erase, and find nothing left - not
    /// "eventually", immediately after the `await` returns.
    @MainActor
    @Test func stopAndEraseStoreLeavesNothingBehindTheInstantItReturns() async throws {
        let backend = FakeBackend(world: .minimal)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: FixtureWorld.minimal.me)

        try await model.start()
        // Proof the fixture actually seeded something, so an empty store
        // after erasing means "erased" rather than "never populated".
        var seeded = false
        for _ in 0 ..< 200 {
            seeded = try !store.conversations().isEmpty
            if seeded {
                break
            }
            await Task.yield()
        }
        #expect(seeded)

        try await model.stopAndEraseStore()

        #expect(try store.conversations().isEmpty)
        #expect(try store.me() == nil)
    }

    /// The exact repro a review round found: open a conversation whose
    /// history fetch hangs, sign out - `stopAndEraseStore()` - and only then
    /// let the hung request finally answer. Without `historyTask` tracked and
    /// cancelled, and without `loadMoreMessages`'s own cancellation check,
    /// the late answer would upsert `msg:late` into a store this session no
    /// longer owns, right after `stopAndEraseStore()` had already erased it.
    @MainActor
    @Test func aHistoryFetchThatOutlivesStopCannotWriteAfterTheErase() async throws {
        let backend = HangingHistoryBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: Member.ID("people/me"))
        let conversation = Conversation.ID("space:1")

        try await model.start()
        model.select(conversation)

        // Gives `select`'s Task a moment to actually reach `loadMessages` and
        // block inside it, so the erase below finds a genuinely in-flight
        // request rather than one that has not started.
        for _ in 0 ..< 50 {
            await Task.yield()
        }

        try await model.stopAndEraseStore()

        // The hung request "finally answers" only now - after signing out
        // has already cancelled the task that was waiting on it and erased
        // the store it would have written to.
        await backend.releaseHungRequest()
        for _ in 0 ..< 50 {
            await Task.yield()
        }

        #expect(try store.messages(in: conversation).isEmpty)
    }
}
