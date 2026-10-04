import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// The person's own reaction: written at once, sent addressed, undone on
/// refusal.
@MainActor
struct ReactTests {
    private struct Harness {
        let backend: RecordingBackend
        let store: ChatStore
        let model: ChatSessionModel
        let message: Message
    }

    private func running(capabilities: Capabilities = .fixture) async throws -> Harness {
        let backend = RecordingBackend(capabilities: capabilities)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: nil, markReadDebounce: .zero)
        try await model.start()
        await settleAutoMarkRead()
        let message = FixtureWorld.minimal.messages[0]
        model.select(message.conversationID)
        await settleAutoMarkRead()
        try #require(model.messages.contains { $0.id == message.id })
        return Harness(backend: backend, store: store, model: model, message: message)
    }

    private func stored(_ harness: Harness) throws -> [Reaction] {
        try harness.store.messages(in: harness.message.conversationID)
            .first { $0.id == harness.message.id }?.reactions ?? []
    }

    @Test func aReactionIsWrittenAtOnceAndSentAddressed() async throws {
        let harness = try await running()
        let before = try stored(harness)
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "🛞"), add: true)
        #expect(try stored(harness) == before.applying(ReactionChoice(emoji: "🛞"), add: true))
        await settleAutoMarkRead()
        let sent = await harness.backend.commands.last
        #expect(sent == .setReaction(
            messageID: harness.message.id, emoji: "🛞", add: true,
            conversationID: harness.message.conversationID, threadID: harness.message.threadID,
            customEmoji: nil
        ))
        await harness.model.stop()
    }

    @Test func aRefusalPutsThePreviousSetBack() async throws {
        let harness = try await running()
        let before = try stored(harness)
        await harness.backend.failSubmissions(true)
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "🛞"), add: true)
        await settleAutoMarkRead()
        #expect(try stored(harness) == before)
        #expect(harness.model.lastError != nil)
        await harness.model.stop()
    }

    /// Review Focus 2: the second toggle folds against the first's write.
    @Test func twoQuickTogglesCancelOut() async throws {
        let harness = try await running()
        let before = try stored(harness)
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "🛞"), add: true)
        await settleAutoMarkRead()
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "🛞"), add: false)
        await settleAutoMarkRead()
        #expect(try stored(harness) == before)
        await harness.model.stop()
    }

    @Test func aToggleThatChangesNothingSendsNothing() async throws {
        let harness = try await running()
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "🛞"), add: false)
        await settleAutoMarkRead()
        #expect(await !harness.backend.commands
            .contains {
                if case .setReaction = $0 {
                    true
                } else {
                    false
                }
            })
        await harness.model.stop()
    }

    @Test func withoutTheCapabilityNothingHappens() async throws {
        var capabilities = Capabilities.fixture
        capabilities.canReact = false
        let harness = try await running(capabilities: capabilities)
        let before = try stored(harness)
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "🛞"), add: true)
        await settleAutoMarkRead()
        #expect(try stored(harness) == before)
        #expect(await harness.backend.commands
            .allSatisfy {
                if case .setReaction = $0 {
                    false
                } else {
                    true
                }
            })
        await harness.model.stop()
    }

    /// Review Focus 1: an optimistic message has no server id to react to.
    @Test func anUnsentMessageCannotBeReactedTo() async throws {
        let harness = try await running()
        let local = Message(
            id: Message.ID("local/l-1"), conversationID: harness.message.conversationID,
            threadID: MessageThread.ID(""), sender: Member.ID("u-1"), text: "x",
            createdAt: Date(timeIntervalSince1970: 2_000_000_000), localID: "l-1"
        )
        try harness.store.apply([.upsertMessage(local)])
        await settleAutoMarkRead()
        try #require(harness.model.messages.contains { $0.id == local.id })
        harness.model.react(to: local.id, with: ReactionChoice(emoji: "🛞"), add: true)
        await settleAutoMarkRead()
        #expect(await harness.backend.commands
            .allSatisfy {
                if case .setReaction = $0 {
                    false
                } else {
                    true
                }
            })
        await harness.model.stop()
    }
}
