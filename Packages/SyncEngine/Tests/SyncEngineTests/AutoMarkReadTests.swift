import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// The automatic mark-read, and the sequences that break a naive version.
///
/// Every test here drives a *sequence*, not a state. That is deliberate:
/// `findings.md` §25.10 records a Critical that passed every per-task test
/// because each test called the thing exactly once, and the defect needed a
/// second call on the same object. Read that section before simplifying any of
/// these into a single-step assertion.
@Suite(.timeLimit(.minutes(1)))
struct AutoMarkReadTests {
    /// The conversation the fixture actually has messages in - picked from the
    /// world rather than from `model.conversations.first`, because a
    /// conversation with no messages has no read position and marks nothing,
    /// which would make half of these tests pass for the wrong reason.
    private var conversation: Conversation.ID {
        FixtureWorld.minimal.messages[0].conversationID
    }

    @MainActor
    private func harness(
        capabilities: Capabilities = .fixture
    ) async throws -> (ChatSessionModel, RecordingBackend) {
        let backend = RecordingBackend(capabilities: capabilities)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: nil)
        try await model.start()
        await settle()
        return (model, backend)
    }

    /// The same polling shape `ChatSessionModelTests` already uses. Session 18
    /// flagged a 200-iteration `Task.yield()` loop as timing-sensitive in
    /// `OptimisticSendTests`; it is reused here rather than inventing a second
    /// waiting idiom, and it is worth someone eventually replacing both.
    ///
    /// **Must be `@MainActor`.** Factoring this loop out as a plain
    /// `nonisolated` `async func` - as first drafted - hops the caller off
    /// the main actor for the duration of the wait. Every observation
    /// callback this suite is waiting on (`ChatSessionModel`'s `watch`/
    /// `observe` closures) is itself scheduled on the main actor, and in
    /// this runtime a nonisolated `Task.yield()` loop never handed the main
    /// thread back to them within the 200-iteration budget: every test built
    /// on this helper measured zero messages loaded and zero mark-read calls,
    /// deterministically, on every run - not flaky, simply wrong. Every
    /// existing settle-style wait in this package (`ChatSessionModelTests`,
    /// `ChatSessionModelTeardownTests`) inlines its loop directly inside an
    /// `@MainActor` test function rather than through a shared nonisolated
    /// helper, which is what hid this from precedent.
    @MainActor
    private func settle() async {
        for _ in 0 ..< 200 {
            await Task.yield()
        }
    }

    @MainActor
    @Test func openingMarksReadOnce() async throws {
        let (model, backend) = try await harness()
        model.select(conversation)
        await settle()

        #expect(await backend.markReadCount == 1)
        await model.stop()
    }

    /// A message arriving while the conversation is open marks again, because
    /// the read position moved.
    @MainActor
    @Test func aNewerMessageMarksAgain() async throws {
        let (model, backend) = try await harness()
        model.select(conversation)
        await settle()
        #expect(await backend.markReadCount == 1)

        model.send("a reply of my own")
        await settle()

        #expect(await backend.markReadCount == 2)
        await model.stop()
    }

    /// **The sequence a single-step test cannot see.** Two deliveries at the
    /// same read position must produce one call, not two - the watermark is
    /// send-side dedupe, and this is the only test that proves it dedupes.
    ///
    /// The brief's own draft drove the second delivery with a focus
    /// round-trip (`setActive(false)` then `setActive(true)`), which is
    /// exactly `aFailedMarkIsRetriedByTheNextTrigger`'s second trigger too -
    /// two tests that look different and are not. This one instead
    /// re-delivers the newest fixture message in `conversation` verbatim via
    /// `store.apply(.upsertMessage(_:))`, the way the store actually receives
    /// a redelivered event: `ChatStore`'s `ValueObservation`s here have no
    /// `removeDuplicates()`, so an identical row re-written still re-emits
    /// `observeMessages`, without moving the newest timestamp and without
    /// touching focus at all.
    @MainActor
    @Test func aRedeliveryAtTheSamePositionMarksNothing() async throws {
        let backend = RecordingBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: nil)
        try await model.start()
        await settle()

        model.select(conversation)
        await settle()
        let afterFirstOpen = await backend.markReadCount

        let redelivered = try #require(
            FixtureWorld.minimal.messages
                .filter { $0.conversationID == conversation }
                .max { $0.createdAt < $1.createdAt }
        )
        try store.apply([.upsertMessage(redelivered)])
        await settle()

        #expect(await backend.markReadCount == afterFirstOpen)
        await model.stop()
    }

    /// Not frontmost, nothing published. This is the whole privacy argument
    /// for the gate: an app open behind another window is not being read.
    @MainActor
    @Test func nothingIsPublishedWhileNotFrontmost() async throws {
        let (model, backend) = try await harness()
        model.setActive(false)
        model.select(conversation)
        await settle()

        #expect(await backend.markReadCount == 0)
        await model.stop()
    }

    /// Coming back to the app marks what is already on screen. Without this,
    /// everything that arrived while the user was away stays unread forever,
    /// because no new message will arrive to trigger it.
    @MainActor
    @Test func returningToFrontmostMarksTheOpenConversation() async throws {
        let (model, backend) = try await harness()
        model.setActive(false)
        model.select(conversation)
        await settle()
        #expect(await backend.markReadCount == 0)

        model.setActive(true)
        await settle()

        #expect(await backend.markReadCount == 1)
        await model.stop()
    }

    /// **The other sequence a single-step test cannot see.** A failed mark
    /// must leave the watermark where it was, so the next trigger retries.
    /// Advancing on issue rather than on success would swallow that retry and
    /// the badge would never clear again for this conversation.
    @MainActor
    @Test func aFailedMarkIsRetriedByTheNextTrigger() async throws {
        let (model, backend) = try await harness()
        await backend.failSubmissions(true)
        model.select(conversation)
        await settle()
        #expect(await backend.markReadCount == 1)

        await backend.failSubmissions(false)
        model.setActive(false)
        model.setActive(true)
        await settle()

        #expect(await backend.markReadCount == 2)
        await model.stop()
    }

    /// A conversation with no messages has no position to publish.
    ///
    /// `FixtureWorld.minimal` has no such conversation - both `dm:1` and
    /// `space:1` carry messages - so this test builds one rather than
    /// searching for it: see the task brief's correction to the original
    /// draft, which always failed its own `#require`.
    @MainActor
    @Test func anEmptyConversationMarksNothing() async throws {
        var world = FixtureWorld.minimal
        world.conversations.append(
            Conversation(id: Conversation.ID("space:empty"), kind: .space, title: "empty")
        )
        let backend = RecordingBackend(world: world)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: nil)
        try await model.start()
        await settle()

        model.select(Conversation.ID("space:empty"))
        await settle()

        #expect(await backend.markReadCount == 0)
        await model.stop()
    }

    /// Ghost mode reaches this path too - proven here rather than inferred
    /// from Task 5's chokepoint test, because the trigger is what a user
    /// actually meets.
    @MainActor
    @Test func ghostModeSilencesTheTrigger() async throws {
        let backend = RecordingBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        await engine.setGhostMode(true)
        let model = ChatSessionModel(store: store, engine: engine, me: nil)
        try await model.start()
        await settle()

        model.select(conversation)
        await settle()

        #expect(await backend.markReadCount == 0)
        await model.stop()
    }

    /// A backend that cannot mark read is never asked. `Capabilities()` is all
    /// flags off, which is the posture a backend that has not thought about a
    /// capability is treated as having.
    @MainActor
    @Test func aBackendWithoutTheCapabilityIsNotAsked() async throws {
        let (model, backend) = try await harness(capabilities: Capabilities())
        model.select(conversation)
        await settle()

        #expect(await backend.markReadCount == 0)
        await model.stop()
    }
}
