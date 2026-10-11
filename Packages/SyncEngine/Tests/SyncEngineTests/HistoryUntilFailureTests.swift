import ChatKit
import FixtureBackend
import Foundation
import GRDB
import Synchronization
import Testing
@testable import SyncEngine

/// Opening a hit when something goes wrong (search spec §1.3): an open
/// canceled mid-page, a page that fails, and a store that refuses or loses
/// the hit. `HistoryUntilTests`' world and fixtures, split out for
/// swiftlint's `file_length`.
@Suite(.timeLimit(.minutes(1)))
struct HistoryUntilFailureTests {
    static let space = HistoryUntilTests.space
    static let base = HistoryUntilTests.base

    static var farWorld: FixtureWorld {
        HistoryUntilTests.farWorld
    }

    static func root(_ index: Int) -> Message {
        HistoryUntilTests.root(index)
    }

    static func reply(_ id: String, in thread: String, minute: Double) -> Message {
        HistoryUntilTests.reply(id, in: thread, minute: minute)
    }

    static func engine(
        _ store: ChatStore, world: FixtureWorld = HistoryUntilTests.world
    ) -> (SyncEngine, RecordingBackend) {
        HistoryUntilTests.engine(store, world: world)
    }

    static func stored(_ store: ChatStore) throws -> Set<String> {
        try HistoryUntilTests.stored(store)
    }

    /// A store that counts its error writes at the connection: `lastError` is
    /// one slot, so a failure recorded twice looks the same in it as once.
    static func countingErrors() throws -> (ChatStore, ErrorWrites) {
        let writes = ErrorWrites()
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.trace { writes.record($0) }
        }
        return try (ChatStore(DatabaseQueue(configuration: configuration)), writes)
    }

    /// Makes the store refuse to insert one message, as a full disk or a
    /// damaged database refuses a write.
    static func refuse(_ id: String, in store: ChatStore) throws {
        try store.database.write { db in
            try db.execute(sql: """
            CREATE TEMP TRIGGER refuseOne BEFORE INSERT ON message WHEN NEW.id = '\(id)'
            BEGIN SELECT RAISE(ABORT, 'refused'); END
            """)
        }
    }

    // MARK: - A canceled open writes nothing

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

    /// A sign-out, a step to another hit or ✕ cancels the open while its
    /// first page is on the wire: the hold throws, as the transport's request
    /// does, and neither the page nor the hit lands. So the next open of the
    /// same hit asks again, rather than finding it stored alone.
    @Test func anOpenCanceledDuringItsFirstPageStoresNothing() async throws {
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
        #expect(try Self.stored(store).isEmpty)
        // A sign-out is not a failure: nothing reaches the error banner.
        #expect(try store.lastError() == nil)

        await backend.holdHistory(false)
        let target = try await engine.loadHistory(in: Self.space, until: Self.root(10), pageLimit: 20)
        #expect(target == HistoryTarget(message: Self.root(10), threadRoot: nil))
        #expect(await backend.historyCursors == [Message.ID("h10"), Message.ID("h10")])
        #expect(try Self.stored(store) == ["h7", "h8", "h9", "h10"])
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
        #expect(try Self.stored(store).isEmpty)
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
        #expect(try Self.stored(store).isEmpty)
    }

    // MARK: - A failed page still opens the hit

    /// A first page that fails is recorded where errors show, once, and the
    /// hit is stored alone and still opens: without what led up to it, rather
    /// than not at all. The next open of it asks for that page again.
    @Test func aFailedFirstPageStoresTheHitAloneAndIsRecordedOnce() async throws {
        let (store, errors) = try Self.countingErrors()
        let (engine, backend) = Self.engine(store)
        await backend.failHistory(true)
        let hit = Self.root(10)
        let target = try await engine.loadHistory(in: Self.space, until: hit, pageLimit: 20)
        #expect(target == HistoryTarget(message: hit, threadRoot: nil))
        #expect(await backend.historyCursors == [hit.id])
        #expect(try store.lastError() == .notAuthenticated)
        #expect(errors.value == 1)
        #expect(try Self.stored(store) == ["h10"])

        await backend.failHistory(false)
        _ = try await engine.loadHistory(in: Self.space, until: hit, pageLimit: 20)
        #expect(await backend.historyCursors == [hit.id, hit.id])
        #expect(try Self.stored(store) == ["h7", "h8", "h9", "h10"])
    }

    /// A reply's later page that fails is recorded too, and the reply opens
    /// with the first page's context, its root not reached.
    @Test func aLaterPageThatFailsIsRecordedAndTheReplyStillOpens() async throws {
        let (store, errors) = try Self.countingErrors()
        let (engine, backend) = Self.engine(store, world: Self.farWorld)
        await backend.holdHistory(true)
        let hit = Self.reply("late", in: "t0", minute: 20.5)
        let task = Task {
            try await engine.loadHistory(in: Self.space, until: hit, pageLimit: 20)
        }
        await settleAutoMarkRead(until: "the first page is held") { await backend.abortableHistory.count == 1
        }
        await backend.abortableHistory.release()
        await settleAutoMarkRead(until: "the second page is held") {
            let asked = await backend.historyCursors.count
            let held = await backend.abortableHistory.count
            return asked == 2 && held == 1
        }
        await backend.failHistory(true)
        await backend.abortableHistory.release()
        let target = try await task.value
        #expect(target == HistoryTarget(message: hit, threadRoot: nil))
        #expect(try store.lastError() == .notAuthenticated)
        #expect(errors.value == 1)
        #expect(try Self.stored(store) == ["late", "h18", "h19", "h20"])
    }

    // MARK: - A hit the store refuses or loses

    /// A store that refuses the hit's write: the failure is recorded where
    /// errors show, once, rather than lost, and the open fails.
    @Test func aHitTheStoreRefusesIsRecordedOnceAndThrown() async throws {
        let (store, errors) = try Self.countingErrors()
        try Self.refuse("h10", in: store)
        let (engine, backend) = Self.engine(store)
        await #expect(throws: (any Error).self) {
            _ = try await engine.loadHistory(in: Self.space, until: Self.root(10), pageLimit: 20)
        }
        #expect(await backend.historyCursors == [Message.ID("h10")])
        // The page went in the same write, so none of it landed either.
        #expect(try Self.stored(store).isEmpty)
        #expect(try store.lastError() != nil)
        #expect(errors.value == 1)
    }

    /// With no page asked, the same.
    @Test func aHitTheStoreRefusesWithNoPagesIsRecordedAndThrown() async throws {
        let (store, errors) = try Self.countingErrors()
        try Self.refuse("h10", in: store)
        let (engine, _) = Self.engine(store)
        await #expect(throws: (any Error).self) {
            _ = try await engine.loadHistory(in: Self.space, until: Self.root(10), pageLimit: 0)
        }
        #expect(errors.value == 1)
    }

    /// No target only when the hit is not stored at the end: here something
    /// else removed it while a reply's second and last page was out, after
    /// the first page had stored it. (Paging on to the root would store it
    /// again: the root's page carries its replies.)
    @Test func aHitNoLongerStoredIsNoTarget() async throws {
        let store = try ChatStore.inMemory()
        let (engine, backend) = Self.engine(store, world: Self.farWorld)
        await backend.holdHistory(true)
        let hit = Self.reply("late", in: "t0", minute: 20.5)
        let task = Task {
            try await engine.loadHistory(in: Self.space, until: hit, pageLimit: 2)
        }
        await settleAutoMarkRead(until: "the first page is held") { await backend.abortableHistory.count == 1
        }
        await backend.abortableHistory.release()
        await settleAutoMarkRead(until: "the second page is held") {
            let asked = await backend.historyCursors.count
            let held = await backend.abortableHistory.count
            return asked == 2 && held == 1
        }
        try #require(try store.message(hit.id) != nil)
        try store.apply([.removeMessage(id: hit.id)])
        await backend.holdHistory(false)
        while await !backend.abortableHistory.isEmpty {
            await backend.abortableHistory.release()
        }
        let target = try await task.value
        #expect(target == nil)
        #expect(try store.lastError() == nil)
    }
}

/// The store's `lastError` writes, counted as the connection runs them.
final class ErrorWrites: Sendable {
    private let count = Mutex(0)

    var value: Int {
        count.withLock { $0 }
    }

    func record(_ event: Database.TraceEvent) {
        guard case let .statement(statement) = event, statement.sql.contains("SET lastError") else { return }
        count.withLock { $0 += 1 }
    }
}
