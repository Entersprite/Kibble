import ChatKit
import FixtureBackend
import Foundation
import GRDB
import Testing
@testable import SyncEngine

/// Opening a hit (search spec §1.3): the page just older than the hit is
/// asked for by its id - the bridge anchors that on the hit's own time
/// (`findings.md` §65.9) - and the hit is stored as search found it in the
/// same write as that page, so an open canceled before its page lands
/// stores nothing. A stored hit asks for nothing, unless nothing older than
/// it is stored beside it. A reply's root is paged back to. Kibble otherwise
/// never loads past the newest page.
///
/// What comes back is what the opener lands on, read here rather than on the
/// main thread (CLAUDE.md, session 66): the stored copy, and a reply's root.
@Suite(.timeLimit(.minutes(1)))
struct HistoryUntilTests {
    static let base = FixtureWorld.minimal
    static let space = base.conversations[0].id

    static func root(_ index: Int, minute: Double? = nil) -> Message {
        Message(
            id: Message.ID("h\(index)"), conversationID: space, threadID: MessageThread.ID("t\(index)"),
            sender: base.me, text: "message \(index)",
            createdAt: base.startedAt.addingTimeInterval((minute ?? Double(index)) * 60)
        )
    }

    static func reply(_ id: String, in thread: String, minute: Double) -> Message {
        Message(
            id: Message.ID(id), conversationID: space, threadID: MessageThread.ID(thread),
            sender: base.me, text: "a reply", createdAt: base.startedAt.addingTimeInterval(minute * 60),
            isReply: true
        )
    }

    /// Twenty roots one minute apart, a reply on the oldest half a minute in.
    /// In time order: `FakeBackend` pages by position in this array.
    static var world: FixtureWorld {
        var world = base
        world.messages = [root(0), reply("h0-reply", in: "t0", minute: 0.5)] + (1 ..< 20).map { root($0) }
        return world
    }

    static func engine(_ store: ChatStore, world: FixtureWorld = world) -> (SyncEngine, RecordingBackend) {
        let backend = RecordingBackend(world: world, pageSize: 3)
        return (SyncEngine(backend: backend, store: store), backend)
    }

    /// Every stored message of the conversation, replies included (the
    /// transcript's read leaves them out).
    static func stored(_ store: ChatStore) throws -> Set<String> {
        try store.database.read { db in
            try Set(String.fetchAll(db, sql: "SELECT id FROM message WHERE conversationID = ?", arguments: [
                space.rawValue
            ]))
        }
    }

    // MARK: - The hit, and the page before it

    @Test func anUnstoredHitIsStoredAndOnlyThePageBeforeItIsAsked() async throws {
        let store = try ChatStore.inMemory()
        let (engine, backend) = Self.engine(store)
        let hit = Self.root(10)
        let target = try await engine.loadHistory(in: Self.space, until: hit, pageLimit: 20)
        #expect(target == HistoryTarget(message: hit, threadRoot: nil))
        #expect(await backend.historyCursors == [hit.id])
        #expect(try Self.stored(store) == ["h7", "h8", "h9", "h10"])
    }

    /// A hit lacks reactions, the edit time and app cards (`findings.md`
    /// §65.8), so a stored copy is what opens, untouched, and with a stored
    /// message older than it beside it nothing is asked.
    @Test func aStoredCopyWithOlderContextIsNeitherOverwrittenNorRefetched() async throws {
        let store = try ChatStore.inMemory()
        let (engine, backend) = Self.engine(store)
        var stored = Self.root(10)
        stored.reactions = [Reaction(emoji: "👍", count: 2)]
        stored.editedAt = stored.createdAt.addingTimeInterval(5)
        try store.apply([.upsertMessage(Self.root(9)), .upsertMessage(stored)])
        var hit = Self.root(10)
        hit.text = "as search found it"
        let target = try await engine.loadHistory(in: Self.space, until: hit, pageLimit: 20)
        // The store's copy is what opens, reactions and edit time included.
        #expect(target == HistoryTarget(message: stored, threadRoot: nil))
        #expect(try store.message(hit.id) == stored)
        #expect(await backend.historyCursors.isEmpty)
    }

    /// A stored hit with nothing older stored beside it, as an open whose
    /// page failed leaves it, or a store from before the hit was written with
    /// its page: the newest page does not count, being newer. The page before
    /// it is asked again, and the stored copy still opens, untouched.
    @Test func aStoredHitWithNothingOlderAsksForWhatLedUpToIt() async throws {
        let store = try ChatStore.inMemory()
        let (engine, backend) = Self.engine(store)
        var stored = Self.root(10)
        stored.reactions = [Reaction(emoji: "👍", count: 2)]
        try store.apply((17 ..< 20).map { .upsertMessage(Self.root($0)) } + [.upsertMessage(stored)])
        let target = try await engine.loadHistory(in: Self.space, until: Self.root(10), pageLimit: 20)
        #expect(await backend.historyCursors == [stored.id])
        #expect(try Self.stored(store) == ["h7", "h8", "h9", "h10", "h17", "h18", "h19"])
        #expect(target == HistoryTarget(message: stored, threadRoot: nil))
        #expect(try store.message(stored.id) == stored)
    }

    /// Only a top-level message counts as what led up to a hit: a stored
    /// reply older than it is not in the transcript.
    @Test func anOlderStoredReplyIsNotContext() async throws {
        let store = try ChatStore.inMemory()
        let (engine, backend) = Self.engine(store)
        let olderReply = Self.reply("h0-reply", in: "t0", minute: 0.5)
        try store.apply([.upsertMessage(olderReply), .upsertMessage(Self.root(10))])
        _ = try await engine.loadHistory(in: Self.space, until: Self.root(10), pageLimit: 20)
        #expect(await backend.historyCursors == [Message.ID("h10")])
    }

    /// When the page before the hit is the newest one, as a backend that
    /// ignores the anchor answers, its copy of the hit is the one kept: a
    /// history copy carries what a hit lacks (§65.8).
    @Test func aPageCopyOfTheHitWinsOverTheSearchCopy() async throws {
        let store = try ChatStore.inMemory()
        let (engine, backend) = Self.engine(store)
        await backend.ignoreHistoryCursor(true)
        var hit = Self.root(19)
        hit.text = "as search found it"
        let target = try await engine.loadHistory(in: Self.space, until: hit, pageLimit: 20)
        #expect(try store.message(hit.id)?.text == "message 19")
        #expect(target?.message.text == "message 19")
    }

    /// A limit of none still stores the hit: the open never depends on a page.
    @Test func noPagesStillStoresTheHit() async throws {
        let store = try ChatStore.inMemory()
        let (engine, backend) = Self.engine(store)
        let target = try await engine.loadHistory(in: Self.space, until: Self.root(1), pageLimit: 0)
        #expect(target == HistoryTarget(message: Self.root(1), threadRoot: nil))
        #expect(try Self.stored(store) == ["h1"])
        #expect(await backend.historyCursors.isEmpty)
    }

    // MARK: - A reply's root

    /// The reply keeps `isReply` and its root's thread id.
    @Test func aReplyWhoseRootIsOnThePageBeforeItNeedsOnePage() async throws {
        let store = try ChatStore.inMemory()
        let (engine, backend) = Self.engine(store)
        let hit = Self.reply("h0-reply", in: "t0", minute: 0.5)
        let target = try await engine.loadHistory(in: Self.space, until: hit, pageLimit: 20)
        #expect(await backend.historyCursors == [hit.id])
        let row = try #require(try store.message(hit.id))
        #expect(row.isReply)
        #expect(row.threadID == MessageThread.ID("t0"))
        #expect(try store.message(Message.ID("h0")) != nil)
        // The root is found by the store's thread, never by its id: "h0"
        // names thread "t0".
        #expect(target == HistoryTarget(message: row, threadRoot: Message.ID("h0")))
    }

    /// A root 21 roots before its reply: seven pages of three, each `before:`
    /// the oldest root the last one brought.
    static var farWorld: FixtureWorld {
        var world = base
        world.messages = [root(0)] + (1 ... 20).map { root($0) } + [reply("late", in: "t0", minute: 20.5)]
        return world
    }

    @Test func aReplyPagesBackUntilItsRootIsStored() async throws {
        let store = try ChatStore.inMemory()
        let (engine, backend) = Self.engine(store, world: Self.farWorld)
        let hit = Self.reply("late", in: "t0", minute: 20.5)
        let target = try await engine.loadHistory(in: Self.space, until: hit, pageLimit: 20)
        #expect(target?.threadRoot == Message.ID("h0"))
        #expect(try store.message(Message.ID("h0")) != nil)
        let cursors = await backend.historyCursors
        #expect(cursors.count == 7)
        #expect(cursors.prefix(3) == [hit.id, Message.ID("h18"), Message.ID("h15")])
    }

    @Test func aReplyStopsAtThePageLimitWithItsHitStored() async throws {
        let store = try ChatStore.inMemory()
        let (engine, backend) = Self.engine(store, world: Self.farWorld)
        let hit = Self.reply("late", in: "t0", minute: 20.5)
        let target = try await engine.loadHistory(in: Self.space, until: hit, pageLimit: 2)
        #expect(await backend.historyCursors.count == 2)
        #expect(try store.message(Message.ID("h0")) == nil)
        #expect(try store.message(hit.id)?.isReply == true)
        // The reply still opens, in its thread, with no root to scroll to.
        #expect(target == HistoryTarget(message: hit, threadRoot: nil))
    }

    /// A stored reply asks for nothing, and names its root when that is
    /// stored too.
    @Test func aStoredReplyNamesItsStoredRoot() async throws {
        let store = try ChatStore.inMemory()
        let (engine, backend) = Self.engine(store)
        let hit = Self.reply("h0-reply", in: "t0", minute: 0.5)
        try store.apply([.upsertMessage(Self.root(0)), .upsertMessage(hit)])
        let target = try await engine.loadHistory(in: Self.space, until: hit, pageLimit: 20)
        #expect(target == HistoryTarget(message: hit, threadRoot: Message.ID("h0")))
        #expect(await backend.historyCursors.isEmpty)
    }

    // MARK: - Anchors at either end terminate

    /// Newer than every stored message, and a backend that answers the newest
    /// page whatever it is asked (a server that ignores the anchor): the
    /// second page brings nothing older than the first, so it stops.
    @Test func aHitNewerThanEverythingStoredStopsWhenNothingOlderComes() async throws {
        var world = Self.world
        let hit = Self.reply("newest", in: "gone", minute: 30)
        world.messages.append(hit)
        let store = try ChatStore.inMemory()
        let (engine, backend) = Self.engine(store, world: world)
        try store.apply((10 ..< 20).map { .upsertMessage(Self.root($0)) })
        await backend.ignoreHistoryCursor(true)
        let target = try await engine.loadHistory(in: Self.space, until: hit, pageLimit: 20)
        #expect(target?.message == hit)
        #expect(await backend.historyCursors.count == 2)
    }

    /// Older than the whole conversation: the page before it is empty.
    @Test func aHitOlderThanTheConversationStopsAtAnEmptyPage() async throws {
        var world = Self.world
        let hit = Self.reply("ancient", in: "gone", minute: -1440)
        world.messages.insert(hit, at: 0)
        let store = try ChatStore.inMemory()
        let (engine, backend) = Self.engine(store, world: world)
        let target = try await engine.loadHistory(in: Self.space, until: hit, pageLimit: 20)
        #expect(target?.message == hit)
        #expect(await backend.historyCursors == [hit.id])
        #expect(try Self.stored(store) == ["ancient"])
    }

    /// The same, against a backend that answers the newest page anyway (as
    /// the real one would if the server ignored the anchor and its own filter
    /// did not hold): nothing on it is older than the hit, so one page ends it.
    @Test func aHitOlderThanTheConversationStopsWhenTheNewestPageComesBack() async throws {
        var world = Self.world
        let hit = Self.reply("ancient", in: "gone", minute: -1440)
        world.messages.insert(hit, at: 0)
        let (engine, backend) = try Self.engine(ChatStore.inMemory(), world: world)
        await backend.ignoreHistoryCursor(true)
        let target = try await engine.loadHistory(in: Self.space, until: hit, pageLimit: 20)
        #expect(target?.message == hit)
        #expect(await backend.historyCursors.count == 1)
    }
}
