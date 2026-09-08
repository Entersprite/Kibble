import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// Shared by `AutoMarkReadTests` and `AutoMarkReadReArmTests` - split across
/// two files because the combined suite crossed swiftlint's `file_length`
/// ceiling once the re-arm sequence tests were added. Extracted here rather
/// than duplicated, the same way `RecordingBackend` next door is already
/// shared rather than redefined per test file.
///
/// A named bundle rather than a tuple: swiftlint's `large_tuple` caps tuples
/// at 2 members, and callers need the store itself, not just the model and
/// the backend, to drive a redelivery or a during-flight message directly.
struct AutoMarkReadHarness {
    let model: ChatSessionModel
    let backend: RecordingBackend
    let store: ChatStore
}

/// The conversation the fixture actually has messages in - picked from the
/// world rather than from `model.conversations.first`, because a conversation
/// with no messages has no read position and marks nothing, which would make
/// half of these tests pass for the wrong reason.
var autoMarkReadConversation: Conversation.ID {
    FixtureWorld.minimal.messages[0].conversationID
}

/// `markReadDebounce` defaults to `.zero`, **not** to production's
/// `.seconds(2)`. Every caller of this harness drives the model with
/// `settleAutoMarkRead()`, which is a `Task.yield()` loop and not a wait: two
/// real seconds never elapse inside it, so a two-second default here would
/// leave every one of these suites asserting on a mark that had not happened
/// yet. `.zero` is what leaves the existing callers behaving as they did
/// before the debounce existed; the debounce itself is what
/// `MarkReadDebounceTests` drives, with a real interval.
@MainActor
func makeAutoMarkReadHarness(
    capabilities: Capabilities = .fixture,
    markReadDebounce: Duration = .zero
) async throws -> AutoMarkReadHarness {
    let backend = RecordingBackend(capabilities: capabilities)
    let store = try ChatStore.inMemory()
    let engine = SyncEngine(backend: backend, store: store)
    let model = ChatSessionModel(
        store: store, engine: engine, me: nil, markReadDebounce: markReadDebounce
    )
    try await model.start()
    await settleAutoMarkRead()
    return AutoMarkReadHarness(model: model, backend: backend, store: store)
}

/// The same polling shape `ChatSessionModelTests` already uses. Session 18
/// flagged a 200-iteration `Task.yield()` loop as timing-sensitive in
/// `OptimisticSendTests`; it is reused here rather than inventing a second
/// waiting idiom, and it is worth someone eventually replacing both.
///
/// **Must be `@MainActor`.** Factoring this loop out as a plain `nonisolated`
/// `async func` - as first drafted - hops the caller off the main actor for
/// the duration of the wait. Every observation callback these suites are
/// waiting on (`ChatSessionModel`'s `watch`/`observe` closures) is itself
/// scheduled on the main actor, and in this runtime a nonisolated
/// `Task.yield()` loop never handed the main thread back to them within the
/// 200-iteration budget: every test built on this helper measured zero
/// messages loaded and zero mark-read calls, deterministically, on every
/// run - not flaky, simply wrong. Every existing settle-style wait in this
/// package (`ChatSessionModelTests`, `ChatSessionModelTeardownTests`) inlines
/// its loop directly inside an `@MainActor` test function rather than through
/// a shared nonisolated helper, which is what hid this from precedent.
@MainActor
func settleAutoMarkRead() async {
    for _ in 0 ..< 200 {
        await Task.yield()
    }
}

/// How long a predicate settle keeps polling before it gives up and records
/// an issue.
///
/// A **deadline, not a wait**: a healthy run never reaches it, because
/// `settleAutoMarkRead(until:holds:)` returns on the first poll where its
/// condition holds. It is set far above every interval these suites use
/// (`markReadSequenceInterval` is 200ms, the feature suite's is 50ms) so that
/// reaching it means something is actually wrong rather than that the machine
/// was briefly busy - which is the whole point of expressing the bound as a
/// timeout instead of as a yield count.
let markReadSettleTimeout = Duration.seconds(5)

/// Drains the main actor **until `condition` holds**, and records an issue
/// naming `subject` if it has not held by `timeout`.
///
/// **This exists because `settleAutoMarkRead()`'s 200 yields are an
/// assumption about wall time, and the assumption was measured false.** The
/// whole-branch review of this branch ran the three debounce suites under
/// artificial CPU load and reproduced six distinct failures - four of them in
/// the 200ms suites, not only the 50ms ones - every one of which was the same
/// shape: a fixed yield budget consumed part of the debounce interval, so the
/// interleaved event the test was about landed *after* the wait it was
/// supposed to land inside, and the sequence under test never happened.
/// Widening the interval only moves that threshold; polling a predicate
/// removes it, because a settle that stops the instant its condition holds
/// consumes the minimum rather than a guessed amount.
///
/// **Must be `@MainActor`**, for exactly the reason `settleAutoMarkRead()`'s
/// own doc comment records: a nonisolated yield loop never hands the main
/// thread back to the main-actor-isolated observation callbacks these suites
/// are waiting on, so every test built on it measures zero while the store
/// genuinely holds rows - deterministically wrong rather than flaky. The
/// condition is `@MainActor` and `async` for the same reason and one more:
/// several of these predicates read `RecordingBackend`, which is an actor.
///
/// **A timeout is a loud failure, not a quiet return.** A predicate helper
/// that gives up silently converts a flake into a confusing downstream
/// assertion failure somewhere else in the test - which is the failure mode
/// this helper exists to remove, reintroduced by the helper itself. The
/// recorded issue names `subject`, so the report says what was being waited
/// for rather than only which later expectation went red.
///
/// **The poll backs off from yields to a real sleep, and that is
/// load-bearing rather than tidiness.** Swift Testing runs this package's
/// tests in parallel, and every test in these suites is `@MainActor`, so they
/// all queue on one actor. A yield-only poll therefore does not just wait -
/// it *hogs* the shared main actor, starving the GRDB observation delivery
/// that another concurrently-running test is itself waiting on. Measured:
/// the store-write-to-`messages` round trip is ~1.5ms when a test runs alone
/// even under 576 busy processes, and the failures only appear when the
/// suites run together. So the first few polls are yields, for the fast path
/// where the condition is already nearly true, and after that the loop sleeps
/// a millisecond at a time, which hands the main actor back rather than
/// spinning on it.
@MainActor
func settleAutoMarkRead(
    until subject: String,
    within timeout: Duration = markReadSettleTimeout,
    sourceLocation: SourceLocation = #_sourceLocation,
    holds condition: @MainActor () async -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    var polls = 0
    while await !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record(
                """
                settleAutoMarkRead timed out after \(timeout) and \(polls) \
                polls waiting until \(subject).
                """,
                sourceLocation: sourceLocation
            )
            return
        }
        polls += 1
        await Task.yield()
        if polls > 4 {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

/// The newest fixture position in `autoMarkReadConversation` - the value a
/// mark scheduled before anything else arrives carries.
///
/// Shared rather than redeclared per suite, the same reasoning
/// `RecordingBackend` next door records: two copies of "what the fixture's
/// newest position is" is two things to get wrong when the fixture changes.
var autoMarkReadFixtureNewest: Date {
    get throws {
        try #require(
            FixtureWorld.minimal.messages
                .filter { $0.conversationID == autoMarkReadConversation }
                .map(\.createdAt).max()
        )
    }
}

/// The newest fixture position in some *other* conversation, so a test can
/// prove a mark carried its own conversation's position rather than whatever
/// was selected when its wait ended.
func autoMarkReadFixtureNewest(in conversation: Conversation.ID) throws -> Date {
    try #require(
        FixtureWorld.minimal.messages
            .filter { $0.conversationID == conversation }
            .map(\.createdAt).max()
    )
}

/// Writes a server-shaped message into `autoMarkReadConversation`, strictly
/// newer than every fixture one by `secondsAfterFixture`.
///
/// A real id, not a `local/` one, so the trigger's own filter counts it -
/// an optimistic row would be filtered out and the test would pass for the
/// wrong reason.
@MainActor
func landAutoMarkReadMessage(
    in store: ChatStore, id: String, secondsAfterFixture: TimeInterval
) throws {
    let base = FixtureWorld.minimal.messages[0]
    let newest = try autoMarkReadFixtureNewest
    try store.apply([.upsertMessage(Message(
        id: Message.ID(id),
        conversationID: autoMarkReadConversation,
        threadID: base.threadID,
        sender: base.sender,
        text: "arrived during the wait",
        createdAt: newest.addingTimeInterval(secondsAfterFixture)
    ))])
}

/// Writes a whole burst of server-shaped messages into
/// `autoMarkReadConversation` in **one** `store.apply`, each strictly newer
/// than every fixture one by its own offset.
///
/// One transaction rather than a call per message, and that is the point
/// rather than brevity. Each `store.apply` produces its own GRDB observation
/// delivery, and a coalescing test has to wait for the *newest* row to reach
/// `messages` before the debounce interval expires. Three separate writes
/// means waiting for the third of three deliveries; one write means waiting
/// for one. Measured under whole-package parallelism plus heavy external CPU
/// load, that delivery is the single largest cost in these tests - stalls of
/// several hundred milliseconds against ~1.5ms for the same harness run
/// alone - so the number of deliveries a test has to survive is worth
/// minimising.
@MainActor
func landAutoMarkReadBurst(
    in store: ChatStore, _ rows: [(id: String, secondsAfterFixture: TimeInterval)]
) throws {
    let base = FixtureWorld.minimal.messages[0]
    let newest = try autoMarkReadFixtureNewest
    try store.apply(rows.map { row in
        .upsertMessage(Message(
            id: Message.ID(row.id),
            conversationID: autoMarkReadConversation,
            threadID: base.threadID,
            sender: base.sender,
            text: "arrived during the wait",
            createdAt: newest.addingTimeInterval(row.secondsAfterFixture)
        ))
    })
}

/// Writes one of this session's own **unacknowledged** optimistic rows into
/// `autoMarkReadConversation` - a `local/`-prefixed id and a wall-clock
/// `createdAt`, which is what `send(_:)` inserts before the server echoes the
/// real message back.
///
/// The shape matters and is the point: the fixture's positions are dated in
/// the past, so a `Date()` row is strictly newer than every server position
/// in the conversation. That is the state in which an *unfiltered* "is there
/// anything newer than what I published?" test is permanently true, which is
/// what `aFailedMarkWithAnUnackedLocalRowDoesNotLoop` drives.
@MainActor
func landUnackedLocalMessage(in store: ChatStore, id: String) throws {
    let base = FixtureWorld.minimal.messages[0]
    try store.apply([.upsertMessage(Message(
        id: Message.ID(id),
        conversationID: autoMarkReadConversation,
        threadID: base.threadID,
        sender: base.sender,
        text: "not yet acknowledged",
        createdAt: Date()
    ))])
}

/// Every read position this session published, oldest first.
func markReadPositions(from backend: RecordingBackend) async -> [Date] {
    await markReads(from: backend).map(\.position)
}

/// Every mark this session published, as the conversation it named paired
/// with the position it carried. A named 2-tuple rather than a struct because
/// swiftlint's `large_tuple` allows two members, and both halves are needed
/// together: a mark that names the right conversation with another one's
/// position is the exact defect the mid-wait switch rule exists to stop.
func markReads(from backend: RecordingBackend) async -> [(
    conversation: Conversation.ID, position: Date
)] {
    await backend.commands.compactMap { command in
        if case let .markRead(conversationID, upTo) = command {
            (conversation: conversationID, position: upTo)
        } else {
            nil
        }
    }
}

/// The debounce interval the sequence suites run with.
///
/// Four times the `.milliseconds(50)` `MarkReadDebounceTests` uses. It was
/// widened for a reason that has since been **measured wrong**: the claim was
/// that a wider interval buys margin for the fixed 200-yield settle that has
/// to run before an interleaved event can be placed inside the wait. The
/// whole-branch review put the three debounce suites under artificial CPU
/// load and found the widening bought no real margin - it moved the failure
/// threshold, and four of the six reproduced failures were in *these* 200ms
/// suites rather than the 50ms ones.
///
/// **What removed the assumption is `settleAutoMarkRead(until:holds:)`**, not
/// this number. Every wait in these suites now stops on the first poll where
/// the thing it is waiting for is true, so the interval is no longer being
/// spent on a yield budget before the test gets to act. The interval is left
/// at 200ms rather than narrowed back: with the fixed budget gone it is
/// simply the window an interleaved event has to land inside, and a wider
/// window is free.
let markReadSequenceInterval = Duration.milliseconds(200)

/// `AutoMarkReadHarness` plus the trace sink.
///
/// A separate type rather than a fourth field on that one: every existing
/// caller of `makeAutoMarkReadHarness` passes no sink, and a `nil` sink is
/// the fast path the trace's own contract is written around, so the two
/// shapes are kept apart rather than one made optional.
///
/// The sink is what lets a sequence test say *which guard* declined rather
/// than only that nothing happened. "No second mark" is true both when the
/// in-flight guard suppressed a trigger and when that trigger never fired at
/// all, and those are different code paths with different bugs.
struct TracedMarkReadHarness {
    let model: ChatSessionModel
    let backend: RecordingBackend
    let store: ChatStore
    let sink: FakeMarkReadTraceSink
}

@MainActor
func makeTracedMarkReadHarness(
    markReadDebounce: Duration = markReadSequenceInterval
) async throws -> TracedMarkReadHarness {
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
    try await model.start()
    await settleAutoMarkRead()
    return TracedMarkReadHarness(model: model, backend: backend, store: store, sink: sink)
}

/// How many trigger rows carry a given token.
///
/// Sequence tests assert on counts of specific tokens rather than on the
/// whole ordered list, because `select(_:)` emits a leading
/// `noServerMessages` before history lands and a mid-wait switch can emit an
/// extra `watermarkNotAdvanced`, neither of which any sequence is about.
@MainActor
func markReadTriggerCount(
    _ outcome: MarkReadTriggerOutcome, in harness: TracedMarkReadHarness
) -> Int {
    harness.sink.triggers.count { $0.outcome == outcome }
}
