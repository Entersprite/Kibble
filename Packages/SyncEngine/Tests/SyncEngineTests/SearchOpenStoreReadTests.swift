import ChatKit
import FixtureBackend
import Foundation
import GRDB
import Synchronization
import Testing
@testable import ChatPersistence
@testable import SyncEngine

/// Opening a search hit reads the store on the engine, never on the main
/// thread (CLAUDE.md, session 66). The store is one serial queue, so a read
/// from the main thread waits behind every write and its observations'
/// re-fetches, and history pages are landing while a hit opens.
///
/// Counted at the connection, through GRDB's statement trace, because no
/// observer can see a read, and `@Observable` skips an equal value (session
/// 66). Each test ends with a positive control: `open(conversation:message:)`
/// reads on the main thread, so a counter that sees nothing fails there.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SearchOpenStoreReadTests {
    static let world = SearchOpenTests.world
    static let space = SearchOpenTests.space

    /// The search's model over a store whose connection reports every
    /// statement it runs on the main thread.
    private struct Traced {
        let model: ChatSessionModel
        let store: ChatStore
        let statements: MainThreadStatements
        /// What the directory refresh reads (`refreshDirectory()`), which
        /// every observation delivery runs on the main thread. It is the
        /// delivery's read, not the open's, so it is counted apart.
        let directoryRead: Set<String>
    }

    private static func searched(_ hit: Message, in world: FixtureWorld) async throws -> Traced {
        let statements = MainThreadStatements()
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.trace { statements.record($0) }
        }
        let store = try ChatStore(DatabaseQueue(configuration: configuration))
        let backend = RecordingBackend(world: world, pageSize: 3)
        await backend.scriptMessageSearch([MessageSearchPage(hits: [hit])])
        // A mark waits `markReadDebounce` before it reads anything, so an
        // hour keeps the marks' own work out of what is counted here.
        let model = ChatSessionModel(
            store: store, engine: SyncEngine(backend: backend, store: store), me: world.me,
            markReadDebounce: .seconds(3600), directoryDebounce: .zero, membershipWait: .milliseconds(50),
            searchDebounce: .zero
        )
        try await model.start()
        model.showSearch()
        model.searchTextChanged("deploy")
        await settleAutoMarkRead(until: "hits") { !model.search.hits.isEmpty }
        statements.arm()
        _ = try store.members()
        let directoryRead = Set(statements.disarm().filter(Self.touchesATable))
        try #require(!directoryRead.isEmpty)
        return Traced(model: model, store: store, statements: statements, directoryRead: directoryRead)
    }

    /// A statement that reads or writes a table. GRDB wraps every access in
    /// transaction and `query_only` statements, which say nothing about which.
    private static func touchesATable(_ sql: String) -> Bool {
        let verb = sql.prefix { !$0.isWhitespace }.uppercased()
        return !["BEGIN", "COMMIT", "ROLLBACK", "PRAGMA", "SAVEPOINT", "RELEASE"].contains(verb)
    }

    private static func reads(_ traced: Traced) -> [String] {
        traced.statements.disarm().filter { touchesATable($0) && !traced.directoryRead.contains($0) }
    }

    @Test func openingARootReadsNothingOnTheMainThread() async throws {
        let hit = SearchOpenTests.hit(1)
        let traced = try await Self.searched(hit, in: Self.world)
        let model = traced.model
        traced.statements.arm()
        model.openSearchResult(hit.id)
        await settleAutoMarkRead(until: "it opens") { model.search.highlight == hit.id }
        let opened = Self.reads(traced)
        #expect(opened.isEmpty, "read on the main thread: \(opened)")
        #expect(model.scrollTarget == hit.id)
        #expect(model.selected == Self.space)

        // The positive control: the counter sees a main-thread read.
        traced.statements.arm()
        model.open(conversation: Self.space, message: hit.id)
        #expect(!Self.reads(traced).isEmpty)
        await model.stop()
    }

    /// A reply opens its thread and scrolls the transcript to its root, both
    /// named by the engine.
    @Test func openingAReplyReadsNothingOnTheMainThread() async throws {
        let root = SearchOpenTests.hit(5)
        let reply = Message(
            id: Message.ID("r5"), conversationID: Self.space, threadID: root.threadID,
            sender: Self.world.me, text: "deploy reply",
            createdAt: root.createdAt.addingTimeInterval(30), isReply: true
        )
        var world = Self.world
        world.messages.insert(reply, at: 6)
        let traced = try await Self.searched(reply, in: world)
        let model = traced.model
        traced.statements.arm()
        model.openSearchResult(reply.id)
        await settleAutoMarkRead(until: "it opens") { model.search.highlight == reply.id }
        let opened = Self.reads(traced)
        #expect(opened.isEmpty, "read on the main thread: \(opened)")
        #expect(model.scrollTarget == root.id)
        #expect(model.threads.openThread == root.threadID)
        #expect(model.threads.scrollTarget == reply.id)

        traced.statements.arm()
        model.open(conversation: Self.space, message: reply.id)
        #expect(!Self.reads(traced).isEmpty)
        await model.stop()
    }
}

/// The statements a connection runs on the main thread while armed.
///
/// A `DatabaseQueue` runs a synchronous read or write through
/// `DispatchQueue.sync`, which runs the block on the calling thread, so the
/// trace sees the caller's thread. The positive controls are what show that
/// holds here.
final class MainThreadStatements: Sendable {
    private struct Log {
        var armed = false
        var statements: [String] = []
    }

    private let log = Mutex(Log())

    func record(_ event: Database.TraceEvent) {
        guard Thread.isMainThread, case let .statement(statement) = event else { return }
        let sql = statement.sql
        log.withLock { log in
            if log.armed {
                log.statements.append(sql)
            }
        }
    }

    /// Starts recording afresh.
    func arm() {
        log.withLock { $0 = Log(armed: true) }
    }

    /// Stops recording, and hands back what was recorded since `arm()`.
    func disarm() -> [String] {
        log.withLock { log in
            log.armed = false
            return log.statements
        }
    }
}
