import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// Recents (reactions spec §3; slice 2 plan Task 2): what the person reacted
/// with, newest first, written only when an add was accepted.
@MainActor
struct EmojiRecentsTests {
    private static let parrot = CustomEmojiRef(id: "e-1", shortcode: ":parrot:", imageToken: "rt")

    // MARK: - The store

    @Test func aSecondUseMovesAnEmojiToTheFront() throws {
        let store = try ChatStore.inMemory()
        try store.recordReactionUse(ReactionChoice(emoji: "👍"), at: Date(timeIntervalSince1970: 10))
        try store.recordReactionUse(ReactionChoice(emoji: "🎉"), at: Date(timeIntervalSince1970: 20))
        try store.recordReactionUse(ReactionChoice(emoji: "👍"), at: Date(timeIntervalSince1970: 30))
        #expect(try store.recentReactions(limit: 10).map(\.emoji) == ["👍", "🎉"])
        #expect(try store.recentReactions(limit: 1).map(\.emoji) == ["👍"])
    }

    @Test func aCustomRecentKeepsItsReferenceAndToken() throws {
        let store = try ChatStore.inMemory()
        try store.recordReactionUse(
            ReactionChoice(customEmoji: Self.parrot),
            at: Date(timeIntervalSince1970: 10)
        )
        let recent = try #require(try store.recentReactions(limit: 10).first)
        #expect(recent == ReactionChoice(customEmoji: Self.parrot))
        #expect(recent.customEmoji?.imageToken == "rt")
    }

    /// Review Focus 2: sign-out's erase takes the recents with it.
    @Test func theEraseRemovesTheRecents() throws {
        let store = try ChatStore.inMemory()
        try store.recordReactionUse(ReactionChoice(emoji: "👍"), at: Date(timeIntervalSince1970: 10))
        try store.erase()
        #expect(try store.recentReactions(limit: 10).isEmpty)
    }

    @Test func storedCustomEmojiAreDistinctAndPreferATokenedReference() throws {
        let store = try ChatStore.inMemory()
        let tokenless = CustomEmojiRef(id: "e-1", shortcode: ":parrot:")
        let other = CustomEmojiRef(id: "e-2", shortcode: ":cat:")
        let world = FixtureWorld.minimal
        let base = world.messages[0]
        var first = base
        first.reactions = [Reaction(emoji: tokenless.displayText, count: 1, customEmoji: tokenless)]
        var second = Message(
            id: Message.ID("m-second"), conversationID: base.conversationID, threadID: base.threadID,
            sender: base.sender, text: "x", createdAt: base.createdAt.addingTimeInterval(1)
        )
        second.reactions = [
            Reaction(emoji: Self.parrot.displayText, count: 2, customEmoji: Self.parrot),
            Reaction(emoji: other.displayText, count: 1, customEmoji: other),
            Reaction(emoji: "👍", count: 1)
        ]
        try store.apply([
            .replaceConversations(world.conversations),
            .upsertMessage(first),
            .upsertMessage(second)
        ])
        let found = try store.storedCustomEmoji()
        #expect(Set(found.map(\.id)) == ["e-1", "e-2"])
        #expect(found.first { $0.id == "e-1" }?.imageToken == "rt")
    }

    // MARK: - The model

    private struct Harness {
        let backend: RecordingBackend
        let model: ChatSessionModel
        let message: Message
    }

    private func running() async throws -> Harness {
        let backend = RecordingBackend(capabilities: .fixture)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: nil, markReadDebounce: .zero)
        try await model.start()
        await settleAutoMarkRead()
        let message = FixtureWorld.minimal.messages[0]
        model.select(message.conversationID)
        await settleAutoMarkRead()
        try #require(model.messages.contains { $0.id == message.id })
        return Harness(backend: backend, model: model, message: message)
    }

    @Test func anAcceptedAddBecomesARecent() async throws {
        let harness = try await running()
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "🛞"), add: true)
        await settleAutoMarkRead()
        #expect(harness.model.recentReactions(limit: 6).map(\.emoji) == ["🛞"])
        await harness.model.stop()
    }

    /// Review Focus 1: a refused add is not something the person used.
    @Test func aRefusedAddIsNotARecent() async throws {
        let harness = try await running()
        await harness.backend.failSubmissions(true)
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "🛞"), add: true)
        await settleAutoMarkRead()
        #expect(harness.model.recentReactions(limit: 6).isEmpty)
        await harness.model.stop()
    }

    /// A remove would move 🛞 back in front of 🎉 if it were recorded.
    @Test func aRemoveIsNotARecent() async throws {
        let harness = try await running()
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "🛞"), add: true)
        await settleAutoMarkRead()
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "🎉"), add: true)
        await settleAutoMarkRead()
        harness.model.react(to: harness.message.id, with: ReactionChoice(emoji: "🛞"), add: false)
        await settleAutoMarkRead()
        #expect(harness.model.recentReactions(limit: 6).map(\.emoji) == ["🎉", "🛞"])
        await harness.model.stop()
    }
}
