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
    /// A burst during the wait produces ONE mark, not one per message.
    @MainActor
    @Test func aBurstDuringTheWaitProducesOneMark() async throws {
        let harness = try await makeAutoMarkReadHarness(markReadDebounce: .milliseconds(50))
        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead()

        try landAutoMarkReadMessage(in: harness.store, id: "srv-a", secondsAfterFixture: 10)
        try landAutoMarkReadMessage(in: harness.store, id: "srv-b", secondsAfterFixture: 20)
        try landAutoMarkReadMessage(in: harness.store, id: "srv-c", secondsAfterFixture: 30)
        await settleAutoMarkRead()
        try await Task.sleep(for: .milliseconds(150))
        await settleAutoMarkRead()

        #expect(await markReadPositions(from: harness.backend).count == 1)
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

        try landAutoMarkReadMessage(in: harness.store, id: "srv-late", secondsAfterFixture: 42)
        await settleAutoMarkRead()
        try await Task.sleep(for: .milliseconds(150))
        await settleAutoMarkRead()

        let expected = try autoMarkReadFixtureNewest.addingTimeInterval(42)
        #expect(await markReadPositions(from: harness.backend) == [expected])
        await harness.model.stop()
    }

    /// Losing focus during the wait publishes nothing. The gate is re-checked
    /// after the wait as well as before it, because two seconds is long enough
    /// for the user to leave.
    ///
    /// **The settle before `setActive(false)` is what makes this test about
    /// the post-wait guard at all**, and its first version did not have one.
    /// `isActive` starts `true`, so dropping focus in the same synchronous
    /// run as `select(_:)` means no mark is ever scheduled and the *pre*-wait
    /// guard declines - deleting `publishReadPosition`'s own `guard isActive`
    /// left that version green, which is the definition of no coverage.
    /// Settling first schedules the mark, and focus then goes away while it
    /// is waiting, which is the sequence the doc comment claims.
    @MainActor
    @Test func losingFocusDuringTheWaitPublishesNothing() async throws {
        let harness = try await makeAutoMarkReadHarness(markReadDebounce: .milliseconds(50))
        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead()
        // The positive control. Without it, "nothing was published" and
        // "nothing was ever scheduled" are the same observation, and this
        // test cannot tell the guard working from the guard being absent.
        #expect(harness.model.markTasks[autoMarkReadConversation] != nil)
        #expect(await markReadPositions(from: harness.backend).isEmpty)

        harness.model.setActive(false)
        try await Task.sleep(for: .milliseconds(150))
        await settleAutoMarkRead()

        #expect(await markReadPositions(from: harness.backend).isEmpty)
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
        let marks = await markReads(from: harness.backend)
        let forOriginal = marks.filter { $0.conversation == autoMarkReadConversation }
        #expect(forOriginal.count == 1)
        #expect(try forOriginal.first?.position == autoMarkReadFixtureNewest)
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

        #expect(await markReadPositions(from: harness.backend).isEmpty)
        #expect(harness.model.published[autoMarkReadConversation] == nil)
        #expect(harness.model.markTasks[autoMarkReadConversation] == nil)
    }

    /// A failed submit leaves the watermark unadvanced so a later trigger
    /// retries - the rule the whole re-arm rests on, and the one a debounce
    /// could plausibly break by advancing on schedule rather than on success.
    ///
    /// **Named for what it actually drives.** It runs with `.zero`, so there
    /// is no wait in it and it claims nothing about one: it is a regression
    /// guard that the pre-existing watermark rule survived moving the submit
    /// behind a suspension point. `AutoMarkReadTests.aFailedMarkIsRetriedByTheNextTrigger`
    /// is the same invariant from the other side; this one additionally
    /// asserts `published` itself rather than only the call count.
    @MainActor
    @Test func aFailedSubmitLeavesTheWatermarkUnadvanced() async throws {
        let harness = try await makeAutoMarkReadHarness(markReadDebounce: .zero)
        await harness.backend.failSubmissions(true)
        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead()
        let afterFailure = await markReadPositions(from: harness.backend).count
        #expect(afterFailure == 1)
        #expect(harness.model.published[autoMarkReadConversation] == nil)

        await harness.backend.failSubmissions(false)
        harness.model.setActive(false)
        harness.model.setActive(true)
        await settleAutoMarkRead()

        #expect(await markReadPositions(from: harness.backend).count == afterFailure + 1)
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

    /// A `submitted` row must name the conversation the mark **acted on**,
    /// not whatever is selected by the time the wait ends.
    ///
    /// The debounce put a suspension point between the decision and the row,
    /// and `traceTrigger(_:)` reads `selected` and `messages` fresh by
    /// design. So a switch mid-wait used to emit a `submitted` *trigger* row
    /// carrying the new conversation's token and the new conversation's
    /// `newestAgeSeconds`, paired with a `markOutcome` row carrying the old
    /// conversation's token - two rows about one mark, disagreeing about
    /// which conversation it was. `findings.md` §12.2 is what that costs: the
    /// live verification of this whole fix decides "debounce live or build
    /// stale" by reading `newestAgeSeconds` off exactly this row.
    ///
    /// Asserted two independent ways, because either alone can pass while
    /// the field is wrong. The tokens must *pair*: every `submitted` row's
    /// conversation must be one an outcome row also names, and both
    /// conversations must appear. And the two ages must be ~180s apart,
    /// which is the fixture's own gap between `dm:1`'s newest and `space:1`'s
    /// - with the defect both rows report the same conversation's age and
    /// the spread collapses to nothing. The second check is what makes this
    /// about `newestAgeSeconds` rather than only about the id.
    @MainActor
    @Test func aSubmittedRowNamesTheConversationItsMarkActedOn() async throws {
        let harness = try tracedHarness(markReadDebounce: .milliseconds(50))
        try await harness.model.start()
        await settleAutoMarkRead()

        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead()
        let other = try #require(
            harness.model.conversations.first { $0.id != autoMarkReadConversation }
        )
        harness.model.select(other.id)
        await settleAutoMarkRead()
        try await Task.sleep(for: .milliseconds(150))
        await settleAutoMarkRead()

        let submitted = harness.sink.triggers.filter { $0.outcome == .submitted }
        #expect(submitted.count == 2)
        let submittedTokens = Set(submitted.compactMap(\.conversation))
        let outcomeTokens = Set(harness.sink.outcomes.map(\.conversation))
        #expect(submittedTokens.count == 2)
        #expect(submittedTokens == outcomeTokens)

        let ages = submitted.compactMap(\.newestAgeSeconds).sorted()
        #expect(ages.count == 2)
        if ages.count == 2 {
            let spread = ages[1] - ages[0]
            let fixtureGap = 180.0
            #expect(abs(spread - fixtureGap) < 5)
        }
    }
}
