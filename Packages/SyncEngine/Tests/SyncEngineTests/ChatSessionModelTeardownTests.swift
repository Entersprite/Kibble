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

    /// Unreachable in production today - a fresh model is built per session -
    /// but a model reused across sign-out and sign-in must not carry a stale
    /// read watermark or a retained failed draft into the next account.
    /// `markGeneration` is deliberately **not** asserted here: it must
    /// survive `stop()` unreset, per its own doc comment's ABA warning.
    @MainActor
    @Test func stopClearsPublishedWatermarksAndTheFailedDraft() async throws {
        let backend = RecordingBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: FixtureWorld.minimal.me)
        try await model.start()
        for _ in 0 ..< 50 {
            await Task.yield()
        }

        let conversation = FixtureWorld.minimal.messages[0].conversationID
        model.select(conversation)
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        #expect(!model.published.isEmpty)

        await backend.failSubmissions(true)
        model.send("never made it")
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        #expect(model.failedDraft != nil)

        await model.stop()

        #expect(model.published.isEmpty)
        #expect(model.failedDraft == nil)
    }
}

/// The bug the owner actually saw: switching conversations faster than
/// `list_topics` returns produced "Connection problem: the /api/ list_topics
/// call: transport error (NSURLErrorDomain -999)" - our own cancellation,
/// reported as though the network had failed.
///
/// `SyncEngine.requestMoreMessages` used to catch `is CancellationError`, but
/// cancelling `historyTask` (see `ChatSessionModel.select(_:)` and `.stop()`)
/// only cancels the `Task`; it never guarantees the backend underneath
/// throws Swift's own `CancellationError` - `URLSessionTransport` throws
/// `URLError(.cancelled)`, which `LocalBridgeBackend.chatError(fromAPI:call:)`
/// then turns into an ordinary-looking `ChatError.transport(...)`, same as
/// any other failed call. `HangingHistoryBackend.releaseHungRequest(throwing:)`
/// answers a hung fetch with exactly that shape - a `ChatError`, never
/// `CancellationError` - so these tests key the fix on `Task.isCancelled`
/// rather than on what the backend happened to throw, and prove the two
/// scenarios that shape alone cannot tell apart: whether *our* task asked to
/// stop.
@Suite(.timeLimit(.minutes(1)))
struct CancelledHistoryFetchReportingTests {
    /// `historyTask` is ours, and `stop()` cancels it. The backend then
    /// answers the (still-hanging) fetch with a transport-shaped failure, the
    /// same one the owner saw - and it must never reach `lastError`, because
    /// nothing here failed: the session simply stopped caring first.
    @MainActor
    @Test func aFetchCancelledByOurOwnTaskIsNeverRecorded() async throws {
        let backend = HangingHistoryBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: Member.ID("people/me"))
        let conversation = Conversation.ID("space:1")

        try await model.start()
        model.select(conversation)

        // Gives `select`'s Task a moment to actually reach `loadMessages` and
        // block inside it, so `stop()` below cancels a genuinely in-flight
        // fetch rather than one that has not started.
        for _ in 0 ..< 50 {
            await Task.yield()
        }

        // Cancels `historyTask` without erasing anything - the guarantee
        // under test is about reporting, not storage.
        await model.stop()

        // The hung request "finally answers" only now - after our own
        // cancellation - with the exact shape `URLSessionTransport` produces
        // for a cancelled call, never `CancellationError` itself.
        await backend.releaseHungRequest(throwing: ChatError.transport(
            "the /api/ list_topics call: transport error (NSURLErrorDomain -999)"
        ))
        for _ in 0 ..< 50 {
            await Task.yield()
        }

        #expect(try store.lastError() == nil)
    }

    /// The same error shape, but nothing here ever cancelled anything: the
    /// fetch is still the one `select(_:)` started, and it is answered while
    /// still current. Whatever produced this failure was not this session's
    /// own teardown, so it is still news and must still reach `lastError` -
    /// otherwise the fix above would have gone too far and started
    /// swallowing every `.cancelled`-shaped failure, ours or not.
    @MainActor
    @Test func anEquivalentErrorNotCausedByOurCancellationIsStillRecorded() async throws {
        let backend = HangingHistoryBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: Member.ID("people/me"))
        let conversation = Conversation.ID("space:1")

        try await model.start()
        model.select(conversation)

        for _ in 0 ..< 50 {
            await Task.yield()
        }

        // Nobody cancelled `historyTask` - it is still the one fetch this
        // session asked for when the backend answers it with a failure that
        // merely looks identical to the one above.
        await backend.releaseHungRequest(throwing: ChatError.transport(
            "the /api/ list_topics call: transport error (NSURLErrorDomain -999)"
        ))

        var lastError: ChatError?
        for _ in 0 ..< 200 {
            lastError = try store.lastError()
            if lastError != nil {
                break
            }
            await Task.yield()
        }
        #expect(try #require(lastError) == .transport(
            "the /api/ list_topics call: transport error (NSURLErrorDomain -999)"
        ))

        await model.stop()
    }
}
