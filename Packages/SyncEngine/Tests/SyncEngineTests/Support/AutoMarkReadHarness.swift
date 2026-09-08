import ChatKit
import FixtureBackend
import Foundation
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

@MainActor
func makeAutoMarkReadHarness(
    capabilities: Capabilities = .fixture
) async throws -> AutoMarkReadHarness {
    let backend = RecordingBackend(capabilities: capabilities)
    let store = try ChatStore.inMemory()
    let engine = SyncEngine(backend: backend, store: store)
    let model = ChatSessionModel(store: store, engine: engine, me: nil)
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
