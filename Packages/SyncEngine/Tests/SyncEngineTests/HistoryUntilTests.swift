import ChatKit
import FixtureBackend
import Foundation
import GRDB
import Testing
@testable import SyncEngine

/// Opening a hit (search spec §1.3): the hit is stored as search found it,
/// unless the store holds it already, and the page just older than it is
/// asked for by its id - the bridge anchors that on the hit's own time
/// (`findings.md` §65.9). A reply's root is paged back to. Kibble otherwise
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
    /// §65.8), so a stored copy is what opens, untouched, and nothing is asked.
    @Test func aStoredCopyIsNeitherOverwrittenNorRefetched() async throws {
        let store = try ChatStore.inMemory()
        let (engine, backend) = Self.engine(store)
        var stored = Self.root(10)
        stored.reactions = [Reaction(emoji: "👍", count: 2)]
        stored.editedAt = stored.createdAt.addingTimeInterval(5)
        try store.apply([.upsertMessage(stored)])
        var hit = Self.root(10)
        hit.text = "as search found it"
        let target = try await engine.loadHistory(in: Self.space, until: hit, pageLimit: 20)
        // The store's copy is what opens, reactions and edit time included.
        #expect(target == HistoryTarget(message: stored, threadRoot: nil))
        #expect(try store.message(hit.id) == stored)
        #expect(await backend.historyCursors.isEmpty)
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

    /// Review Focus 1: the reply keeps `isReply` and its root's thread id.
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

    // MARK: - Review Focus 3: anchors at either end terminate

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

    // MARK: - Review Focus 4: a canceled open writes nothing more

    @Test func aLoadCanceledBeforeItStartsWritesNothing() async throws {
        let store = try ChatStore.inMemory()
        let (engine, backend) = Self.engine(store)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.loadHistory(in: Self.space, until: Self.root(1), pageLimit: 20)
        }
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(try store.messages(in: Self.space).isEmpty)
        #expect(await backend.historyCursors.isEmpty)
        #expect(try store.lastError() == nil)
    }

    /// A sign-out cancels the open while its page is on the wire: the hold
    /// throws, as the transport's request does, and no page lands.
    @Test func aSignOutDuringTheFetchWritesNoPage() async throws {
        let store = try ChatStore.inMemory()
        let (engine, backend) = Self.engine(store)
        await backend.holdHistory(true)
        let task = Task {
            try await engine.loadHistory(in: Self.space, until: Self.root(10), pageLimit: 20)
        }
        await settleAutoMarkRead(until: "the page is held") { await backend.abortableHistory.count == 1 }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await backend.abortableHistory.aborted == 1)
        #expect(try Self.stored(store) == ["h10"])
        // A sign-out is not a failure: nothing reaches the error banner.
        #expect(try store.lastError() == nil)
    }

    /// A page that answers despite the cancel, as a transport may: the check
    /// after the await keeps it out.
    @Test func aPageAnsweredAfterTheCancelIsNotWritten() async throws {
        let store = try ChatStore.inMemory()
        let backend = GatedHistoryBackend(world: Self.base.conversations)
        await backend.answer(Self.space, with: [Self.root(7), Self.root(8), Self.root(9)])
        let engine = SyncEngine(backend: backend, store: store)
        let task = Task {
            try await engine.loadHistory(in: Self.space, until: Self.root(10), pageLimit: 20)
        }
        await settleAutoMarkRead(until: "the page is parked") { await backend.parkedCount == 1 }
        task.cancel()
        await backend.openGate()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(try Self.stored(store) == ["h10"])
        #expect(try store.lastError() == nil)
    }

    /// A cancellation the transport reports as an ordinary failure, as
    /// `URLSessionTransport`'s `URLError(.cancelled)` reaches the engine: our
    /// own task asked to stop, so it is not recorded
    /// (`SyncEngine.requestMoreMessages`' reasoning).
    @Test func aCancellationShapedLikeAFailureIsNotRecorded() async throws {
        let store = try ChatStore.inMemory()
        let backend = HangingHistoryBackend()
        let engine = SyncEngine(backend: backend, store: store)
        let task = Task {
            try await engine.loadHistory(in: Self.space, until: Self.root(10), pageLimit: 20)
        }
        await settleAutoMarkRead(until: "the page is hung") { await backend.isHoldingARequest }
        task.cancel()
        await backend.releaseHungRequest(throwing: ChatError.transport(
            "the /api/ list_topics call: transport error (NSURLErrorDomain -999)"
        ))
        await #expect(throws: (any Error).self) {
            try await task.value
        }
        #expect(try store.lastError() == nil)
        #expect(try Self.stored(store) == ["h10"])
    }

    // MARK: - A failed page still opens the hit

    /// Once the hit is stored, a page that fails is recorded where errors
    /// show, and the hit still opens: without what led up to it, rather than
    /// not at all.
    @Test func aFailedPageIsRecordedAndTheHitStillOpens() async throws {
        let store = try ChatStore.inMemory()
        let (engine, backend) = Self.engine(store)
        await backend.failHistory(true)
        let hit = Self.root(10)
        let target = try await engine.loadHistory(in: Self.space, until: hit, pageLimit: 20)
        #expect(target == HistoryTarget(message: hit, threadRoot: nil))
        #expect(await backend.historyCursors == [hit.id])
        #expect(try store.lastError() == .notAuthenticated)
        #expect(try Self.stored(store) == ["h10"])
    }

    /// No target only when the hit is not stored at the end: here something
    /// else removed it while its page was out.
    @Test func aHitNoLongerStoredIsNoTarget() async throws {
        let store = try ChatStore.inMemory()
        let (engine, backend) = Self.engine(store)
        await backend.holdHistory(true)
        let hit = Self.root(10)
        let task = Task {
            try await engine.loadHistory(in: Self.space, until: hit, pageLimit: 20)
        }
        await settleAutoMarkRead(until: "the page is held") { await backend.abortableHistory.count == 1 }
        try #require(try store.message(hit.id) != nil)
        try store.apply([.removeMessage(id: hit.id)])
        await backend.holdHistory(false)
        await backend.abortableHistory.release()
        let target = try await task.value
        #expect(target == nil)
        #expect(try store.lastError() == nil)
    }
}
