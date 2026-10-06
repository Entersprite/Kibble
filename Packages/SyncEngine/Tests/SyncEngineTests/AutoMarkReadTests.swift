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
    /// The two re-arm sequence tests (a delivery during a *re-armed*
    /// mark's flight, and `stop()` cancelling a re-armed mark) moved to
    /// `AutoMarkReadReArmTests.swift` once adding them crossed swiftlint's
    /// `file_length` ceiling here - the harness they share with this suite
    /// lives in `Support/AutoMarkReadHarness.swift`.
    private typealias Harness = AutoMarkReadHarness

    private var conversation: Conversation.ID {
        autoMarkReadConversation
    }

    @MainActor
    private func harness(capabilities: Capabilities = .fixture) async throws -> Harness {
        try await makeAutoMarkReadHarness(capabilities: capabilities)
    }

    @MainActor
    private func settle() async {
        await settleAutoMarkRead()
    }

    @MainActor
    @Test func openingMarksReadOnce() async throws {
        let harnessResult = try await harness()
        let model = harnessResult.model
        let backend = harnessResult.backend
        model.select(conversation)
        await settle()

        #expect(await backend.markReadCount == 1)
        await model.stop()
    }

    /// A message arriving while the conversation is open marks again, because
    /// the read position moved.
    @MainActor
    @Test func aNewerMessageMarksAgain() async throws {
        let harnessResult = try await harness()
        let model = harnessResult.model
        let backend = harnessResult.backend
        model.select(conversation)
        await settle()
        #expect(await backend.markReadCount == 1)

        model.send(ComposedMessage(text: "a reply of my own"))
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
        let model = ChatSessionModel(store: store, engine: engine, me: nil, markReadDebounce: .zero)
        try await model.start()
        await settle()

        model.select(conversation)
        await settle()
        let afterFirstOpen = await backend.markReadCount
        // Without this, the test passes in three different broken worlds:
        // the first open marked nothing, the redelivery below never reached
        // `observeMessages` so no second trigger happened at all, or the
        // intended dedupe genuinely worked. Only pinning the baseline first
        // rules out the first two.
        #expect(afterFirstOpen == 1)

        let redelivered = try #require(
            FixtureWorld.minimal.messages
                .filter { $0.conversationID == conversation }
                .max { $0.createdAt < $1.createdAt }
        )
        try store.apply([.upsertMessage(redelivered)])
        await settle()

        #expect(await backend.markReadCount == afterFirstOpen)

        // The positive control: prove the observation was live throughout,
        // not merely quiet. Without this, "no second trigger fired" and
        // "dedupe worked" are indistinguishable - a strictly later message
        // must still move the count, right after the redelivery that must
        // not.
        var newer = redelivered
        newer.id = Message.ID("fixture-seed-newer")
        newer.createdAt = redelivered.createdAt.addingTimeInterval(60)
        try store.apply([.upsertMessage(newer)])
        await settle()

        #expect(await backend.markReadCount == afterFirstOpen + 1)
        await model.stop()
    }

    /// Not frontmost, nothing published. This is the whole privacy argument
    /// for the gate: an app open behind another window is not being read.
    @MainActor
    @Test func nothingIsPublishedWhileNotFrontmost() async throws {
        let harnessResult = try await harness()
        let model = harnessResult.model
        let backend = harnessResult.backend
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
        let harnessResult = try await harness()
        let model = harnessResult.model
        let backend = harnessResult.backend
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
        let harnessResult = try await harness()
        let model = harnessResult.model
        let backend = harnessResult.backend
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
        let model = ChatSessionModel(store: store, engine: engine, me: nil, markReadDebounce: .zero)
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
        let model = ChatSessionModel(store: store, engine: engine, me: nil, markReadDebounce: .zero)
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
        let harnessResult = try await harness(capabilities: Capabilities())
        let model = harnessResult.model
        let backend = harnessResult.backend
        model.select(conversation)
        await settle()

        #expect(await backend.markReadCount == 0)
        await model.stop()
    }

    /// **A third sequence a single-step test cannot see, and the review's own
    /// finding against this task's first draft.** A message that arrives
    /// while a mark is already in flight is suppressed by the
    /// `markTasks[selected] == nil` guard and must not simply be dropped:
    /// without a re-check once the in-flight mark completes, the newest
    /// message of a burst is exactly the one that never gets published,
    /// because nothing later ever arrives to trigger it again.
    ///
    /// Driving this needs the first mark to still be in flight when the
    /// second message lands, which needs `RecordingBackend.holdSubmissions`
    /// to keep its `send(_:)` call open on demand - a `select(_:)` alone
    /// cannot hold that window because `FakeBackend.send` returns instantly.
    @MainActor
    @Test func aMessageArrivingDuringAnInFlightMarkIsNotDropped() async throws {
        let harnessResult = try await harness()
        let model = harnessResult.model
        let backend = harnessResult.backend
        let store = harnessResult.store
        await backend.holdSubmissions(true)

        // Opens the conversation, which starts a mark for the fixture's
        // newest message and blocks on `send(_:)` inside `RecordingBackend`.
        model.select(conversation)
        await settle()
        #expect(await backend.markReadCount == 1)

        // A newer message lands while that mark is still in flight. The
        // in-flight guard suppresses a second call here - this assertion is
        // what proves the suppression, not a bug, is what happened.
        let newest = try #require(
            FixtureWorld.minimal.messages
                .filter { $0.conversationID == conversation }
                .max { $0.createdAt < $1.createdAt }
        )
        var duringFlight = newest
        duringFlight.id = Message.ID("fixture-seed-during-flight")
        duringFlight.createdAt = newest.createdAt.addingTimeInterval(60)
        try store.apply([.upsertMessage(duringFlight)])
        await settle()
        #expect(await backend.markReadCount == 1)

        // Releasing the held mark lets it complete, which is what must
        // re-check and fire once more for the position that arrived during
        // the flight - not zero times (dropped) and not a retry loop.
        // `holdSubmissions(false)` first: the re-check's own `submit` is a
        // second `send(_:)` call, and if the gate were still open it would
        // block on it too, forever, since nothing would ever release it.
        await backend.holdSubmissions(false)
        await backend.releaseHeldSubmission()
        await settle()

        #expect(await backend.markReadCount == 2)
        await model.stop()
    }

    /// **Spec §5.2's reasoning, not its letter.** `send(_:)` writes its
    /// optimistic row with `createdAt: Date()` - a real wall-clock instant,
    /// necessarily later than any fixture timestamp this world uses - so a
    /// naive `newest = messages.map(\.createdAt).max()` treats the optimistic
    /// row itself as a newer read position and issues a `.markRead` call
    /// before the server has echoed anything at all. Worse: that wall-clock
    /// value would poison `published[selected]`, so the server's own echo (a
    /// real, honestly earlier position) never clears `newest <= already` and
    /// is silently never marked.
    ///
    /// `holdSubmissions` freezes every call to `RecordingBackend.send(_:)`
    /// right after `commands.append`, before the fixture's echo can ever be
    /// produced - so while held, `markReadCount` (which counts attempts, not
    /// completions) is exactly the set of calls this session has *tried* to
    /// make so far. That is what lets this test see the premature attempt
    /// directly, rather than inferring its absence from a count that could
    /// equally mean "correctly deferred" or "coincidentally not yet run".
    @MainActor
    @Test func sendingAMessageDoesNotMarkReadOnItsOwn() async throws {
        let backend = RecordingBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(
            store: store,
            engine: engine,
            me: FixtureWorld.minimal.me,
            markReadDebounce: .zero
        )
        try await model.start()
        await settle()

        model.select(conversation)
        await settle()
        #expect(await backend.markReadCount == 1)

        // Holds `sendMessage` itself, before the fixture ever echoes it -
        // the exact window in which a wall-clock-stamped optimistic row
        // would wrongly be seen as a newer read position.
        await backend.holdSubmissions(true)
        model.send(ComposedMessage(text: "a reply of my own"))
        await settle()

        // No second `.markRead` was even attempted from the optimistic row
        // alone - the bug this guards would have appended one to `commands`
        // by now, held or not.
        #expect(await backend.markReadCount == 1)

        // Releasing lets the echo land - a real, later message while open,
        // which spec §3.2's second trigger says must still mark. This is
        // the positive control: the fix must not have gone too far and
        // suppressed marking altogether.
        await backend.holdSubmissions(false)
        await backend.releaseHeldSubmission()
        await settle()

        #expect(await backend.markReadCount == 2)
        await model.stop()
    }
}
