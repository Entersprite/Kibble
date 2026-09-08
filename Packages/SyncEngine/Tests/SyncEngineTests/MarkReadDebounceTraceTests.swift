import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// The two trace tokens the wait introduced, and the row that has to name the
/// conversation its mark acted on - asserted on the *trace* rather than on
/// published positions.
///
/// **Split from `MarkReadDebounceTests` on swiftlint's `file_length`.** That
/// file reached 395 of 400 once the predicate settles and their reasoning
/// landed in it, and `CLAUDE.md`'s stated preference is to split rather than
/// trim a doc comment to fit - the same cut `MarkReadDebounceGuardSequenceTests`
/// already is. The division is the natural one: that file asserts what gets
/// published and what does not, this one asserts what gets *written down*.
///
/// Nothing in this repo switches exhaustively over `MarkReadTriggerOutcome` -
/// `MarkReadTraceFileSink` writes `record.outcome.rawValue` straight out - so
/// the compiler cannot tell anyone that a token is never emitted. Every test
/// in the sibling file asserts on positions, watermarks and tracking entries,
/// all of which would pass with both new tokens dead. That matters beyond
/// tidiness: the live-verification protocol for this fix reads a `submitted`
/// row's `newestAgeSeconds` off a real capture, so a trace path that silently
/// stopped emitting would hand its reader a verdict from a broken instrument.
///
/// `.serialized` for the reason the sibling file's header gives: these are
/// `@MainActor` tests resting on real intervals, and running them against
/// each other on one actor is what the whole-branch review measured breaking.
@Suite(.timeLimit(.minutes(1)), .serialized)
struct MarkReadDebounceTraceTests {
    /// A named bundle rather than a tuple - swiftlint's `large_tuple` caps
    /// tuples at 2 members. Built here rather than borrowed from
    /// `AutoMarkReadTraceTests`' own private one, which takes no interval,
    /// and kept separate from `TracedMarkReadHarness` next door because these
    /// tests need the model *before* `start()` has run: the exact leading
    /// trigger rows are part of what they assert.
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
        await settleAutoMarkRead(until: "the mark has recorded a scheduled row") {
            harness.sink.triggers.contains { $0.outcome == .scheduled }
        }
        #expect(harness.sink.triggers.map(\.outcome) == [.noServerMessages, .scheduled])

        await harness.model.stop()
        await settleAutoMarkRead(until: "the cancelled wait has recorded its own row") {
            harness.sink.triggers.contains { $0.outcome == .cancelledDuringWait }
        }

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
        await settleAutoMarkRead(until: "the first conversation's mark is waiting") {
            harness.model.markTasks[autoMarkReadConversation] != nil
        }
        let other = try #require(
            harness.model.conversations.first { $0.id != autoMarkReadConversation }
        )
        harness.model.select(other.id)
        // Waits on the *outcome* rows rather than the `submitted` ones: a
        // `submitted` row is written before `engine.submit` is awaited, so
        // both of them exist while the second mark's outcome row is still on
        // its way - and the pairing assertion below reads both lists.
        await settleAutoMarkRead(until: "both marks have recorded an outcome row") {
            harness.sink.outcomes.count == 2
        }

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
