import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// Proves `--probe=markread`'s recorder tells the six trigger-decline guards
/// apart, records a submitted mark's outcome, and reports the selected
/// conversation's `unreadCount` transition - the evidence session 21's own
/// four surviving hypotheses need. `MarkReadTraceFileSinkTests` (`MacHost`)
/// covers the CSV writer itself; this suite covers what
/// `MarkReadTraceRecorder` and the trigger hand it.
@Suite(.timeLimit(.minutes(1)))
struct AutoMarkReadTraceTests {
    /// A named bundle rather than a tuple: swiftlint's `large_tuple` caps
    /// tuples at 2 members, and these tests need all four - the model to
    /// drive, the backend to check `markReadCount`, the store to write a
    /// redelivery directly into, and the sink to read the trace back from.
    /// Same reasoning as `AutoMarkReadHarness` next door.
    private struct Harness {
        let model: ChatSessionModel
        let backend: RecordingBackend
        let store: ChatStore
        let sink: FakeMarkReadTraceSink
    }

    private var conversation: Conversation.ID {
        autoMarkReadConversation
    }

    @MainActor
    private func settle() async {
        await settleAutoMarkRead()
    }

    @MainActor
    private func harness(
        capabilities: Capabilities = .fixture,
        world: FixtureWorld = .minimal
    ) throws -> Harness {
        let backend = RecordingBackend(world: world, capabilities: capabilities)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let sink = FakeMarkReadTraceSink()
        let model = ChatSessionModel(
            store: store,
            engine: engine,
            me: nil,
            markReadTrace: sink,
            markReadDebounce: .zero
        )
        return Harness(model: model, backend: backend, store: store, sink: sink)
    }

    /// The happy path: a submitted trigger, an accepted outcome, and the
    /// decisive `5 -> 0` read-state row - `findings.md`'s own separator
    /// between "the trigger declined" and "the server kept a residue".
    ///
    /// `select(_:)` observes messages *before* history has loaded, so the
    /// first observation is always empty - one genuine `noServerMessages`
    /// trigger, then the real one once history arrives. Both are asserted
    /// here rather than hidden, because that leading row is itself real
    /// evidence a capture would show.
    @MainActor
    @Test func openingRecordsSubmittedThenAcceptedThenTheReadStateDrop() async throws {
        var world = FixtureWorld.minimal
        let index = try #require(world.conversations.firstIndex(where: { $0.id == conversation }))
        world.conversations[index].unreadCount = 5
        let harness = try harness(world: world)
        try await harness.model.start()
        await settle()

        harness.model.select(conversation)
        await settle()

        // `scheduled` then `submitted`: the debounce splits what used to be
        // one row into two, and `scheduled` is the row that says a mark was
        // decided on. See `MarkReadTriggerOutcome.scheduled`, and
        // `MarkReadDebounceTests` for the wait itself. Every harness in this
        // suite passes `markReadDebounce: .zero`, so both rows land inside
        // one `settle()`.
        #expect(harness.sink.triggers.map(\.outcome) == [.noServerMessages, .scheduled, .submitted])
        let trigger = try #require(harness.sink.triggers.last)
        #expect(trigger.conversation != nil)
        #expect(trigger.unreadCount == 5)
        #expect(trigger.loadedMessageCount == trigger.filteredMessageCount)
        #expect(trigger.newestAgeSeconds != nil)

        #expect(harness.sink.outcomes.count == 1)
        #expect(harness.sink.outcomes[0].accepted)

        #expect(harness.sink.readStates.map(\.unreadCount) == [0])
        await harness.model.stop()
    }

    @MainActor
    @Test func notFrontmostIsReportedByItsOwnToken() async throws {
        let harness = try harness()
        try await harness.model.start()
        await settle()

        harness.model.setActive(false)
        harness.model.select(conversation)
        await settle()

        // Two evaluations - `select(_:)`'s empty-then-real message
        // observation - but `isActive` is checked first, so both decline
        // with the same token regardless of which observation triggered them.
        #expect(harness.sink.triggers.map(\.outcome) == [.notFrontmost, .notFrontmost])
        #expect(harness.sink.triggers[0].conversation != nil)
        #expect(await harness.backend.markReadCount == 0)
        await harness.model.stop()
    }

    @MainActor
    @Test func cannotMarkReadIsReportedByItsOwnToken() async throws {
        let harness = try harness(capabilities: Capabilities())
        try await harness.model.start()
        await settle()

        harness.model.select(conversation)
        await settle()

        // Same double-evaluation as `notFrontmostIsReportedByItsOwnToken` -
        // `capabilities.canMarkRead` is checked before either message
        // observation can matter, so both declines carry the same token.
        #expect(harness.sink.triggers.map(\.outcome) == [.cannotMarkRead, .cannotMarkRead])
        await harness.model.stop()
    }

    /// `selected == nil` is the one outcome with no conversation to name.
    @MainActor
    @Test func nothingSelectedCarriesNoConversationToken() async throws {
        let harness = try harness()
        try await harness.model.start()
        await settle()

        harness.model.setActive(false)
        harness.model.setActive(true)
        await settle()

        #expect(harness.sink.triggers.map(\.outcome) == [.nothingSelected])
        #expect(harness.sink.triggers[0].conversation == nil)
        #expect(harness.sink.triggers[0].unreadCount == nil)
        await harness.model.stop()
    }

    @MainActor
    @Test func noServerMessagesIsReportedForAnEmptyConversation() async throws {
        var world = FixtureWorld.minimal
        let empty = Conversation.ID("space:empty")
        world.conversations.append(Conversation(id: empty, kind: .space, title: "empty"))
        let harness = try harness(world: world)
        try await harness.model.start()
        await settle()

        harness.model.select(empty)
        await settle()

        #expect(harness.sink.triggers.map(\.outcome) == [.noServerMessages])
        #expect(harness.sink.triggers[0].loadedMessageCount == 0)
        #expect(harness.sink.triggers[0].filteredMessageCount == 0)
        #expect(harness.sink.triggers[0].newestAgeSeconds == nil)
        await harness.model.stop()
    }

    /// The redelivery sequence `AutoMarkReadTests.aRedeliveryAtTheSamePositionMarksNothing`
    /// already proves marks nothing - this proves it is *reported* as
    /// `watermarkNotAdvanced` rather than being indistinguishable from a
    /// second submission.
    @MainActor
    @Test func aRedeliveryAtTheSamePositionIsReportedAsWatermarkNotAdvanced() async throws {
        let harness = try harness()
        try await harness.model.start()
        await settle()

        harness.model.select(conversation)
        await settle()
        #expect(harness.sink.triggers.map(\.outcome) == [.noServerMessages, .scheduled, .submitted])

        let redelivered = try #require(
            FixtureWorld.minimal.messages
                .filter { $0.conversationID == conversation }
                .max { $0.createdAt < $1.createdAt }
        )
        try harness.store.apply([.upsertMessage(redelivered)])
        await settle()

        #expect(harness.sink.triggers.map(\.outcome) == [
            .noServerMessages,
            .scheduled,
            .submitted,
            .watermarkNotAdvanced
        ])
        await harness.model.stop()
    }

    /// The in-flight sequence `AutoMarkReadTests.aMessageArrivingDuringAnInFlightMarkIsNotDropped`
    /// already proves the second delivery is suppressed and later re-checked
    /// - this proves the suppression itself is reported as `alreadyInFlight`.
    @MainActor
    @Test func aDeliveryDuringAnInFlightMarkIsReportedAsAlreadyInFlight() async throws {
        let harness = try harness()
        try await harness.model.start()
        await settle()
        await harness.backend.holdSubmissions(true)

        harness.model.select(conversation)
        await settle()
        #expect(harness.sink.triggers.map(\.outcome) == [.noServerMessages, .scheduled, .submitted])

        let newest = try #require(
            FixtureWorld.minimal.messages
                .filter { $0.conversationID == conversation }
                .max { $0.createdAt < $1.createdAt }
        )
        var duringFlight = newest
        duringFlight.id = Message.ID("fixture-seed-during-flight")
        duringFlight.createdAt = newest.createdAt.addingTimeInterval(60)
        try harness.store.apply([.upsertMessage(duringFlight)])
        await settle()

        #expect(harness.sink.triggers.map(\.outcome) == [
            .noServerMessages,
            .scheduled,
            .submitted,
            .alreadyInFlight
        ])

        await harness.backend.holdSubmissions(false)
        await harness.backend.releaseHeldSubmission()
        await settle()
        await harness.model.stop()
    }

    /// The same conversation must keep the same token across every call in
    /// this session - never the raw id, but stable.
    @MainActor
    @Test func theSameConversationKeepsTheSameTokenAcrossCalls() async throws {
        let harness = try harness()
        try await harness.model.start()
        await settle()

        harness.model.select(conversation)
        await settle()
        harness.model.send(ComposedMessage(text: "a reply of my own"))
        await settle()

        // Not a fixed count: `select(_:)`'s empty-then-real observation and
        // `send(_:)`'s own optimistic-then-echoed write each evaluate more
        // than once. What must hold regardless is that every evaluation
        // named the one conversation this session ever opened.
        let tokens = harness.sink.triggers.compactMap(\.conversation)
        #expect(tokens.count >= 2)
        #expect(Set(tokens).count == 1)
        await harness.model.stop()
    }

    /// A second, distinct conversation gets a different token from the
    /// first - proof the recorder is not just returning a constant.
    @MainActor
    @Test func twoConversationsGetDistinctTokens() async throws {
        var world = FixtureWorld.minimal
        let second = Conversation.ID("space:second")
        world.conversations.append(Conversation(id: second, kind: .space, title: "second", unreadCount: 1))
        world.messages.append(Message(
            id: Message.ID("fixture-second-seed"),
            conversationID: second,
            threadID: MessageThread.ID(""),
            sender: FixtureWorld.minimal.me,
            text: "hi",
            createdAt: Date()
        ))
        let harness = try harness(world: world)
        try await harness.model.start()
        await settle()

        harness.model.select(conversation)
        await settle()
        harness.model.select(second)
        await settle()

        // Not a fixed count, for the same reason as
        // `theSameConversationKeepsTheSameTokenAcrossCalls` - each selection's
        // empty-then-real observation evaluates more than once. What must
        // hold is that exactly two distinct conversations were ever named.
        let tokens = harness.sink.triggers.compactMap(\.conversation)
        #expect(Set(tokens).count == 2)
        await harness.model.stop()
    }

    /// With no sink supplied, the trigger still runs to completion exactly as
    /// it did before this instrument existed - this is the "an ordinary
    /// launch pays nothing, and does not misbehave" half of that claim.
    @MainActor
    @Test func aNilSinkChangesNothingAboutTheOutcome() async throws {
        let backend = RecordingBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: nil, markReadDebounce: .zero)
        try await model.start()
        await settle()

        model.select(conversation)
        await settle()

        #expect(await backend.markReadCount == 1)
        await model.stop()
    }

    /// The two tokens the debounce adds. Raw values are the CSV's own
    /// vocabulary, so they are pinned here rather than left to a rename:
    /// a capture is read by a person weeks later against these strings.
    @Test func theWaitHasItsOwnTokens() {
        #expect(MarkReadTriggerOutcome.scheduled.rawValue == "scheduled")
        #expect(MarkReadTriggerOutcome.cancelledDuringWait.rawValue == "cancelled-during-wait")
    }

    /// `submitted` must keep its token. The debounce splits one evaluation
    /// into two rows - scheduled, then submitted - and a capture is only
    /// readable if the second one still says what it always said.
    @Test func submittedKeepsItsToken() {
        #expect(MarkReadTriggerOutcome.submitted.rawValue == "submitted")
    }
}
