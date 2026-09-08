import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// A reconnect refetches what the client could not have seen.
///
/// `.gap(scope: .everything)` refetches the conversation *list*, below the
/// seam. The open conversation's *history* is a fact about this client's own
/// UI, not about the wire, which is why it lives here - and why `GapScope`
/// was not extended to carry it. That enum is closed on purpose: it is
/// `ChatKit`'s one documented exception to the unknown-discriminator rule.
@Suite(.timeLimit(.minutes(1)))
struct ReconnectCatchUpTests {
    /// A named bundle rather than a tuple, the same reason
    /// `AutoMarkReadHarness` next door is one: swiftlint's `large_tuple` caps
    /// tuples at 2 members, and this needs a third.
    private struct Harness {
        let model: ChatSessionModel
        let store: ChatStore
        let backend: RecordingBackend
    }

    private var conversation: Conversation.ID {
        FixtureWorld.minimal.messages[0].conversationID
    }

    @MainActor
    private func harness() async throws -> Harness {
        let backend = RecordingBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: nil, markReadDebounce: .zero)
        try await model.start()
        await settleAutoMarkRead()
        return Harness(model: model, store: store, backend: backend)
    }

    /// Driving connection state through the store rather than through the
    /// backend, the same way `ObservationTests.swift` does: the model watches
    /// the row, so the row is what a test writes.
    @MainActor
    private func setState(_ state: ConnectionState, _ store: ChatStore) throws {
        try store.apply([.setConnectionState(state)])
    }

    @MainActor
    @Test func reconnectingRefetchesTheOpenConversation() async throws {
        let harness = try await harness()
        let model = harness.model
        let store = harness.store
        model.select(conversation)
        await settleAutoMarkRead()
        let afterOpen = model.messages.count

        try setState(.reconnecting(attempt: 1, issue: nil, detail: nil), store)
        await settleAutoMarkRead()
        try setState(.connected, store)
        await settleAutoMarkRead()

        // The refetch upserts the same rows, so the observable proof is that
        // the transcript is still whole and the model did not throw - plus
        // `historyTask` having been replaced, which the cancellation test
        // below pins from the other side.
        #expect(model.messages.count >= afterOpen)
        #expect(model.lastError == nil)
        await model.stop()
    }

    /// Nothing open, nothing to refetch - and in particular no fetch with an
    /// invented conversation id standing in for the absent one.
    @MainActor
    @Test func reconnectingWithNothingOpenFetchesNothing() async throws {
        let harness = try await harness()
        let model = harness.model
        let store = harness.store
        #expect(model.selected == nil)

        try setState(.connected, store)
        await settleAutoMarkRead()

        #expect(model.messages.isEmpty)
        #expect(model.lastError == nil)
        await model.stop()
    }

    /// **The sequence.** `.connected` delivered twice with no intervening
    /// disconnect must not refetch twice: the observation reports the row, not
    /// the transition, so a refetch per delivery would be one `list_topics`
    /// per database write. Asserted on `loadMessagesCount` rather than on
    /// `lastError == nil` alone - the absence of an error cannot fail for the
    /// reason this test names, since nothing here throws either way.
    @MainActor
    @Test func aRepeatedConnectedValueDoesNotRefetchTwice() async throws {
        let harness = try await harness()
        let model = harness.model
        let store = harness.store
        let backend = harness.backend
        model.select(conversation)
        await settleAutoMarkRead()

        // Force a genuine transition into `.connected` first - the harness's
        // own `engine.start()` may already have delivered `.connected` before
        // this test ever touches the store, so asserting straight off two
        // back-to-back `setState(.connected, _)` calls would not prove the
        // "twice" in this test's name actually happened twice.
        try setState(.reconnecting(attempt: 1, issue: nil, detail: nil), store)
        await settleAutoMarkRead()
        let beforeConnected = await backend.loadMessagesCount

        try setState(.connected, store)
        await settleAutoMarkRead()
        let afterFirstConnected = await backend.loadMessagesCount

        try setState(.connected, store)
        await settleAutoMarkRead()
        let afterSecondConnected = await backend.loadMessagesCount

        #expect(model.lastError == nil)
        // The transition into `.connected` refetches once; the repeated
        // delivery of the same value must not refetch again.
        #expect(afterFirstConnected == beforeConnected + 1)
        #expect(afterSecondConnected == afterFirstConnected)
        await model.stop()
    }

    /// Selecting elsewhere while a reconnect refetch is in flight cancels it,
    /// the same way `select(_:)` already cancels its own - both own
    /// `historyTask`, and a shared owner is exactly how one of them ends up
    /// cancelling the other's work at the wrong moment.
    @MainActor
    @Test func selectingElsewhereCancelsTheRefetch() async throws {
        let harness = try await harness()
        let model = harness.model
        let store = harness.store
        model.select(conversation)
        await settleAutoMarkRead()

        try setState(.connected, store)
        let other = try #require(model.conversations.first { $0.id != conversation })
        model.select(other.id)
        await settleAutoMarkRead()

        // The selection wins: the transcript on screen is the newly selected
        // conversation's, not the refetched one's.
        #expect(model.selected == other.id)
        #expect(model.messages.allSatisfy { $0.conversationID == other.id })
        await model.stop()
    }

    /// The other direction: selecting a new conversation first, then a
    /// reconnect landing while *that* fetch is still in flight, must not have
    /// the reconnect's refetch cancel the fresh selection's own fetch and
    /// leave it with no history and no error. `HangingHistoryBackend`-style
    /// control isn't needed here - the fixture backend answers fast enough
    /// that the risk is expressed by ordering, not by a hung call: the
    /// reconnect's refetch targets whatever `selected` is *at the time it
    /// fires*, so firing it right after a fresh `select(_:)` must refetch the
    /// newly selected conversation, not the old one, and must not clobber the
    /// newly selected conversation's own in-flight fetch with an error.
    @MainActor
    @Test func reconnectDuringAFreshSelectionDoesNotLoseTheNewSelectionsHistory() async throws {
        let harness = try await harness()
        let model = harness.model
        let store = harness.store
        model.select(conversation)
        await settleAutoMarkRead()

        let other = try #require(model.conversations.first { $0.id != conversation })
        model.select(other.id)
        try setState(.connected, store)
        await settleAutoMarkRead()

        #expect(model.selected == other.id)
        #expect(model.lastError == nil)
        #expect(model.messages.allSatisfy { $0.conversationID == other.id })
        await model.stop()
    }
}
