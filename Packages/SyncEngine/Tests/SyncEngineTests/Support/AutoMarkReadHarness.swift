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

/// The debounce interval the sequence suites run with, and a sleep
/// comfortably past it.
///
/// Four times the `.milliseconds(50)` `MarkReadDebounceTests` uses, and
/// deliberately. A test that has to place an event *inside* the wait must
/// first settle to get the mark scheduled, and `settleAutoMarkRead()` is 200
/// yields of real time rather than an instant. Running the whole package
/// suite in parallel was observed to consume more than 50ms across two
/// settles and two selections: the wait had already ended by the time the
/// interleaved event landed, the sequence under test never happened, and the
/// test failed for a reason with nothing to do with the code.
///
/// **This is a measured assumption, not a guarantee** - the same one the
/// existing coalescing tests already rest on, and widening it does not
/// remove it. The change that would remove it is a predicate-polling settle
/// (wait *until* the mark is installed, rather than for a fixed number of
/// yields), which is filed and out of this slice's scope.
let markReadSequenceInterval = Duration.milliseconds(200)
/// Long enough that a sleep of this length guarantees `markReadSequenceInterval`
/// elapsed rather than merely probably elapsed.
let pastMarkReadSequenceInterval = Duration.milliseconds(500)

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
