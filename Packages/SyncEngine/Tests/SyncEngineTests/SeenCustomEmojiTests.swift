import ChatKit
import FixtureBackend
import Foundation
import GRDB
import Testing
@testable import ChatPersistence
@testable import SyncEngine

/// The picker's custom emoji (`ChatSessionModel.customEmoji`): memory every
/// picker reads while it renders, filled once from the stored reactions off
/// the main thread and grown by what is delivered. Until now each picker read
/// every message's reactions on the main thread as it opened.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SeenCustomEmojiTests {
    private static let parrot = CustomEmojiRef(id: "e-1", shortcode: ":parrot:", imageToken: "rt")
    private static let cat = CustomEmojiRef(id: "e-2", shortcode: ":cat:", imageToken: "ct")
    private static let dog = CustomEmojiRef(id: "e-3", shortcode: ":dog:", imageToken: "dt")

    private static func reacted(_ message: Message, with emoji: CustomEmojiRef) -> Message {
        var message = message
        message.reactions.append(Reaction(emoji: emoji.displayText, count: 1, customEmoji: emoji))
        return message
    }

    /// The load reads once, as the session starts. A read queued on the
    /// store's one serial queue after it finishes after it too, and the turns
    /// that follow hand its answer to the model; anything stored later can
    /// reach `customEmoji` only through a delivery.
    private static func settleLoad(_ store: ChatStore) async throws {
        await settleAutoMarkRead()
        try await store.database.read { _ in }
        await settleAutoMarkRead()
    }

    @Test func firstMetComesFirstAndATokenReplacesNone() {
        let tokenless = CustomEmojiRef(id: "e-1", shortcode: ":parrot:")
        var seen = SeenCustomEmoji()
        let added = seen.insert(contentsOf: [tokenless, Self.cat])
        let tokened = seen.insert(contentsOf: [Self.parrot])
        let repeated = seen.insert(contentsOf: [tokenless, Self.cat])
        #expect(added)
        #expect(tokened)
        #expect(!repeated)
        #expect(seen.emoji == [Self.parrot, Self.cat])
    }

    /// What was stored before the session started is there without any
    /// picker asking, and it was read off the main thread. The positive
    /// control reads on the main thread, so a counter that sees nothing fails.
    @Test func storedReactionsLoadOffTheMainThreadAsTheSessionStarts() async throws {
        let statements = MainThreadStatements()
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.trace { statements.record($0) }
        }
        let store = try ChatStore(DatabaseQueue(configuration: configuration))
        let world = FixtureWorld.minimal
        try store.apply([
            .replaceConversations(world.conversations),
            .upsertMessage(Self.reacted(world.messages[2], with: Self.parrot))
        ])
        let model = ChatSessionModel(
            store: store, engine: SyncEngine(backend: RecordingBackend(capabilities: .fixture), store: store),
            markReadDebounce: .seconds(3600)
        )
        statements.arm()
        try await model.start()
        await settleAutoMarkRead(until: "the stored custom emoji are loaded") {
            model.customEmoji == [Self.parrot]
        }
        for _ in 0 ..< 3 {
            _ = model.customEmoji
        }
        let reads = statements.disarm().filter { $0.contains("LIKE '%customEmoji%'") }
        #expect(reads.isEmpty)
        statements.arm()
        _ = try store.recentReactions(limit: 1)
        #expect(!statements.disarm().isEmpty)
        await model.stop()
    }

    @Test func theOpenTranscriptAddsItsCustomReactions() async throws {
        let harness = try await makeAutoMarkReadHarness()
        try await Self.settleLoad(harness.store)
        let message = FixtureWorld.minimal.messages[0]
        harness.model.select(message.conversationID)
        await settleAutoMarkRead(until: "the transcript is shown") {
            harness.model.messages.contains { $0.id == message.id }
        }
        #expect(harness.model.customEmoji.isEmpty)
        try harness.store.apply([.upsertMessage(Self.reacted(message, with: Self.cat))])
        await settleAutoMarkRead(until: "the reaction reaches the picker") {
            harness.model.customEmoji == [Self.cat]
        }
        await harness.model.stop()
    }

    /// A reply's reaction is in the thread panel only: the transcript shows
    /// the thread's first message.
    @Test func theOpenThreadAddsItsRepliesCustomReactions() async throws {
        let harness = try await makeThreadHarness()
        harness.model.setActive(false)
        try await Self.settleLoad(harness.store)
        var messages = ThreadFixture.messages(replies: 2)
        try openStoredThread(messages, in: harness)
        await settleAutoMarkRead(until: "the thread reaches the panel") {
            harness.model.threads.messages.count == 3
        }
        #expect(harness.model.customEmoji.isEmpty)
        messages[2] = Self.reacted(messages[2], with: Self.dog)
        try harness.store.apply([.upsertMessage(messages[2])])
        await settleAutoMarkRead(until: "the reply's reaction reaches the picker") {
            harness.model.customEmoji == [Self.dog]
        }
        #expect(!harness.model.messages.contains { $0.id == messages[2].id })
        await harness.model.stop()
    }

    @Test func customChoicesOlderThanTheRecentLimitRemainAvailableAndStopClearsThem() async throws {
        let store = try ChatStore.inMemory()
        try store.recordReactionUse(
            ReactionChoice(customEmoji: Self.parrot),
            at: Date(timeIntervalSince1970: 1)
        )
        for index in 0 ..< 24 {
            try store.recordReactionUse(
                ReactionChoice(emoji: "unicode-\(index)"),
                at: Date(timeIntervalSince1970: Double(index + 2))
            )
        }
        let backend = RecordingBackend(capabilities: .fixture)
        let model = ChatSessionModel(store: store, engine: SyncEngine(backend: backend, store: store))
        try await model.start()
        await settleAutoMarkRead(until: "the older custom choice is available") {
            model.customEmoji == [Self.parrot]
        }
        #expect(model.recentReactions(limit: 24).allSatisfy { $0.customEmoji == nil })
        let otherStore = try ChatStore.inMemory()
        let other = ChatSessionModel(
            store: otherStore,
            engine: SyncEngine(
                backend: RecordingBackend(capabilities: .fixture),
                store: otherStore
            )
        )
        try await other.start()
        try await Self.settleLoad(otherStore)
        #expect(other.customEmoji.isEmpty)
        await model.stop()
        #expect(model.customEmoji.isEmpty)
        await other.stop()
    }

    @Test func mergingFailedThreadDraftsRetainsBothEmojiAddresses() throws {
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(
            store: store,
            engine: SyncEngine(
                backend: RecordingBackend(capabilities: .fixture),
                store: store
            )
        )
        let key = StagingKey(conversation: .init("chat"), thread: .init("thread"))
        let draft = ComposedMessage(text: Self.parrot.displayText, content: MessageContent(customEmoji: [
            MessageCustomEmoji(emoji: Self.parrot, start: 0, length: Self.parrot.displayText.utf16.count)
        ]))
        model.restoreReply(draft, in: key)
        model.restoreReply(draft, in: key)
        let merged = try #require(model.composerFiles.failedReplies[key])
        let spans = try #require(merged.content?.customEmoji)
        #expect(spans.count == 2)
        #expect(spans.allSatisfy { $0.range(in: merged.text) != nil })
    }

    @Test func forwardedOnlyEmojiReachThePickerAndTheColdStartCatalog() async throws {
        let harness = try await makeAutoMarkReadHarness()
        try await Self.settleLoad(harness.store)
        var received = FixtureWorld.minimal.messages[0]
        harness.model.select(received.conversationID)
        await settleAutoMarkRead(until: "the receiving transcript appears") {
            harness.model.messages.contains { $0.id == received.id }
        }
        var source = MessageQuote(message: received)
        source.text = Self.parrot.displayText
        source.id = .init("original-message")
        let span = MessageCustomEmoji(
            emoji: Self.parrot,
            start: 0,
            length: Self.parrot.displayText.utf16.count
        )
        received.content = MessageContent(forwarded: ForwardedMessage(source: source, customEmoji: [span]))
        try harness.store.apply([.upsertMessage(received)])
        await settleAutoMarkRead(until: "the forwarded custom emoji reaches the picker") {
            harness.model.customEmoji == [Self.parrot]
        }
        let stored = try await harness.store.storedCustomEmoji()
        #expect(stored == [Self.parrot])
        await harness.model.stop()
    }

    @Test func aCustomRecentIsAdded() async throws {
        let harness = try await makeAutoMarkReadHarness()
        try await Self.settleLoad(harness.store)
        #expect(harness.model.customEmoji.isEmpty)
        try harness.store.recordReactionUse(ReactionChoice(customEmoji: Self.parrot), at: Date())
        await settleAutoMarkRead(until: "the recent reaches the picker") {
            harness.model.customEmoji == [Self.parrot]
        }
        await harness.model.stop()
    }
}
