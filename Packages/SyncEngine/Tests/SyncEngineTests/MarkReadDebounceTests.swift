import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// The wait before a read position is published, and the sequences that break
/// a naive version of it.
///
/// Every test drives a *sequence*. `findings.md` §25.10 is a Critical in this
/// repo that passed every test because each test called the thing once, and
/// this slice's own re-arm fix reintroduced its own finding the same way.
///
/// **Two intervals are used deliberately.** Most tests pass `.zero`, because
/// they are about guards and cancellation and a real wait would only slow the
/// suite. The two coalescing tests pass `.milliseconds(50)` and then wait for
/// it, because coalescing is *defined* as "messages arriving during the wait"
/// and `.zero` leaves no wait to arrive during - with `.zero` those messages
/// land during the submit instead, hit `already-in-flight`, and are picked up
/// by the re-arm as a second mark. That would test the re-arm, not the
/// debounce, and would pass while the coalescing was entirely absent.
@Suite(.timeLimit(.minutes(1)))
struct MarkReadDebounceTests {
    /// The newest fixture position in the conversation under test - the value
    /// a mark scheduled before anything else arrives would carry.
    private var fixtureNewest: Date {
        get throws {
            try #require(
                FixtureWorld.minimal.messages
                    .filter { $0.conversationID == autoMarkReadConversation }
                    .map(\.createdAt).max()
            )
        }
    }

    /// Writes a server-shaped message strictly newer than every fixture one.
    /// A real id, not a `local/` one, so the trigger's filter counts it.
    @MainActor
    private func landMessage(
        _ harness: AutoMarkReadHarness, id: String, secondsAfterFixture: TimeInterval
    ) throws {
        let base = FixtureWorld.minimal.messages[0]
        let newest = try fixtureNewest
        try harness.store.apply([.upsertMessage(Message(
            id: Message.ID(id),
            conversationID: autoMarkReadConversation,
            threadID: base.threadID,
            sender: base.sender,
            text: "arrived during the wait",
            createdAt: newest.addingTimeInterval(secondsAfterFixture)
        ))])
    }

    /// Every position this session published, oldest first.
    private func published(_ harness: AutoMarkReadHarness) async -> [Date] {
        await harness.backend.commands.compactMap { command in
            if case let .markRead(_, upTo) = command {
                upTo
            } else {
                nil
            }
        }
    }

    /// A burst during the wait produces ONE mark, not one per message.
    @MainActor
    @Test func aBurstDuringTheWaitProducesOneMark() async throws {
        let harness = try await makeAutoMarkReadHarness(markReadDebounce: .milliseconds(50))
        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead()

        try landMessage(harness, id: "srv-a", secondsAfterFixture: 10)
        try landMessage(harness, id: "srv-b", secondsAfterFixture: 20)
        try landMessage(harness, id: "srv-c", secondsAfterFixture: 30)
        await settleAutoMarkRead()
        try await Task.sleep(for: .milliseconds(150))
        await settleAutoMarkRead()

        #expect(await published(harness).count == 1)
        await harness.model.stop()
    }

    /// The position published is the newest at the END of the wait, not the
    /// one that scheduled it. This is the only test that proves the value
    /// moved rather than merely that one call happened.
    @MainActor
    @Test func thePublishedPositionIsTheNewestAtTheEndOfTheWait() async throws {
        let harness = try await makeAutoMarkReadHarness(markReadDebounce: .milliseconds(50))
        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead()

        try landMessage(harness, id: "srv-late", secondsAfterFixture: 42)
        await settleAutoMarkRead()
        try await Task.sleep(for: .milliseconds(150))
        await settleAutoMarkRead()

        let expected = try fixtureNewest.addingTimeInterval(42)
        #expect(await published(harness) == [expected])
        await harness.model.stop()
    }

    /// Losing focus during the wait publishes nothing. The gate is re-checked
    /// after the wait as well as before it, because two seconds is long enough
    /// for the user to leave.
    @MainActor
    @Test func losingFocusDuringTheWaitPublishesNothing() async throws {
        let harness = try await makeAutoMarkReadHarness(markReadDebounce: .milliseconds(50))
        harness.model.select(autoMarkReadConversation)
        harness.model.setActive(false)
        await settleAutoMarkRead()
        try await Task.sleep(for: .milliseconds(150))
        await settleAutoMarkRead()

        #expect(await published(harness).isEmpty)
        await harness.model.stop()
    }

    /// Switching conversation during the wait publishes the position captured
    /// at schedule time, and must NOT publish some other conversation's newest
    /// timestamp against this conversation's id - after the wait, `messages`
    /// belongs to whatever is selected now.
    @MainActor
    @Test func switchingConversationDuringTheWaitPublishesTheCapturedPosition() async throws {
        let harness = try await makeAutoMarkReadHarness(markReadDebounce: .milliseconds(50))
        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead()

        let other = try #require(
            harness.model.conversations.first { $0.id != autoMarkReadConversation }
        )
        harness.model.select(other.id)
        await settleAutoMarkRead()
        try await Task.sleep(for: .milliseconds(150))
        await settleAutoMarkRead()

        // The first mark is the one scheduled for the original conversation,
        // and it carries that conversation's own newest position.
        let marks = await harness.backend.commands.compactMap { command in
            if case let .markRead(conversationID, upTo) = command {
                (conversationID, upTo)
            } else {
                nil
            }
        }
        let forOriginal = marks.filter { $0.0 == autoMarkReadConversation }
        #expect(forOriginal.count == 1)
        #expect(try forOriginal.first?.1 == fixtureNewest)
        await harness.model.stop()
    }

    /// `stop()` during the wait publishes nothing, advances no watermark, and
    /// leaves no entry behind to wedge the conversation.
    @MainActor
    @Test func stopDuringTheWaitPublishesNothingAndWedgesNothing() async throws {
        let harness = try await makeAutoMarkReadHarness(markReadDebounce: .milliseconds(50))
        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead()

        await harness.model.stop()
        try await Task.sleep(for: .milliseconds(150))
        await settleAutoMarkRead()

        #expect(await published(harness).isEmpty)
        #expect(harness.model.published[autoMarkReadConversation] == nil)
        #expect(harness.model.markTasks[autoMarkReadConversation] == nil)
    }

    /// A failed submit leaves the watermark unadvanced so a later trigger
    /// retries - the rule the whole re-arm rests on, and the one a debounce
    /// could plausibly break by advancing on schedule rather than on success.
    @MainActor
    @Test func aFailedSubmitAfterTheWaitStillRetriesLater() async throws {
        let harness = try await makeAutoMarkReadHarness(markReadDebounce: .zero)
        await harness.backend.failSubmissions(true)
        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead()
        let afterFailure = await published(harness).count
        #expect(afterFailure == 1)
        #expect(harness.model.published[autoMarkReadConversation] == nil)

        await harness.backend.failSubmissions(false)
        harness.model.setActive(false)
        harness.model.setActive(true)
        await settleAutoMarkRead()

        #expect(await published(harness).count == afterFailure + 1)
        await harness.model.stop()
    }

    // The two tokens the wait introduced, asserted on the *trace* rather
    // than on published positions.
    //
    // Nothing in this repo switches exhaustively over
    // `MarkReadTriggerOutcome` - `MarkReadTraceFileSink` writes
    // `record.outcome.rawValue` straight out - so the compiler cannot tell
    // anyone that a token is never emitted. Every other test in this file
    // asserts on positions, watermarks and tracking entries, all of which
    // would pass with both tokens dead. That matters beyond tidiness: the
    // live-verification protocol for this fix reads a `submitted` row's
    // `newestAgeSeconds` off a real capture, so a trace path that silently
    // stopped emitting would hand its reader a verdict from a broken
    // instrument.

    /// A named bundle rather than a tuple - swiftlint's `large_tuple` caps
    /// tuples at 2 members. Built here rather than borrowed from
    /// `AutoMarkReadTraceTests`' own private one, which takes no interval.
    private struct TracedHarness {
        let model: ChatSessionModel
        let sink: FakeMarkReadTraceSink
    }

    @MainActor
    private func tracedHarness(markReadDebounce: Duration) throws -> TracedHarness {
        let backend = RecordingBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let sink = FakeMarkReadTraceSink()
        let model = ChatSessionModel(
            store: store,
            engine: engine,
            me: nil,
            markReadTrace: sink,
            markReadDebounce: markReadDebounce
        )
        return TracedHarness(model: model, sink: sink)
    }

    /// One mark now writes two rows, in this order. `select(_:)` observes
    /// messages before history has loaded, so the leading `noServerMessages`
    /// is real and is asserted rather than hidden - the same leading row
    /// `AutoMarkReadTraceTests` already documents.
    @MainActor
    @Test func aMarkRecordsScheduledThenSubmitted() async throws {
        let harness = try tracedHarness(markReadDebounce: .zero)
        try await harness.model.start()
        await settleAutoMarkRead()

        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead()

        #expect(harness.sink.triggers.map(\.outcome) == [.noServerMessages, .scheduled, .submitted])
        await harness.model.stop()
    }

    /// A wait cut short by `stop()` records `cancelledDuringWait` and never
    /// reaches `submitted`. Without this the token is vocabulary no capture
    /// could ever contain, and the row that explains an abandoned
    /// `scheduled` would be missing exactly when someone needs it.
    @MainActor
    @Test func aCancelledWaitRecordsItsOwnToken() async throws {
        let harness = try tracedHarness(markReadDebounce: .milliseconds(50))
        try await harness.model.start()
        await settleAutoMarkRead()

        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead()
        #expect(harness.sink.triggers.map(\.outcome) == [.noServerMessages, .scheduled])

        await harness.model.stop()
        try await Task.sleep(for: .milliseconds(150))
        await settleAutoMarkRead()

        #expect(harness.sink.triggers.map(\.outcome) == [
            .noServerMessages,
            .scheduled,
            .cancelledDuringWait
        ])
        #expect(harness.sink.outcomes.isEmpty)
    }

    /// The production interval, pinned.
    ///
    /// Every other test in this package injects an interval, and the shared
    /// harness defaults to `.zero`, so without this nothing in the suite
    /// would notice the default being changed - or quietly dropped to
    /// `.zero` by someone tidying away what looks like pointless latency.
    /// `markReadDebounce`'s doc comment is why two seconds.
    @MainActor
    @Test func theDefaultIntervalIsTwoSeconds() throws {
        let backend = RecordingBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine)
        #expect(model.markReadDebounce == Duration.seconds(2))
    }
}
