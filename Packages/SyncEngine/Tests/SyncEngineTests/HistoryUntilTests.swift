import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// Opening a hit pages history back until the hit is stored (search spec
/// §1.3). Kibble otherwise never loads past the newest page.
struct HistoryUntilTests {
    static let base = FixtureWorld.minimal
    static let space = base.conversations[0].id

    /// Twenty roots one minute apart, a reply on the oldest.
    static var world: FixtureWorld {
        var world = base
        world.messages = (0 ..< 20).map { index in
            Message(
                id: Message.ID("h\(index)"), conversationID: space, threadID: MessageThread.ID("t\(index)"),
                sender: base.me, text: "message \(index)",
                createdAt: base.startedAt.addingTimeInterval(Double(index) * 60)
            )
        } + [Message(
            id: Message.ID("h0-reply"), conversationID: space, threadID: MessageThread.ID("t0"),
            sender: base.me, text: "a reply", createdAt: base.startedAt.addingTimeInterval(30), isReply: true
        )]
        return world
    }

    static func engine(pageSize: Int) throws -> (SyncEngine, ChatStore) {
        let store = try ChatStore.inMemory()
        let backend = RecordingBackend(world: world, pageSize: pageSize)
        return (SyncEngine(backend: backend, store: store), store)
    }

    @Test func anOldMessageIsReachedPageByPage() async throws {
        let (engine, store) = try Self.engine(pageSize: 3)
        #expect(try await engine.loadHistory(in: Self.space, until: Message.ID("h1"), pageLimit: 20))
        #expect(try store.message(Message.ID("h1")) != nil)
    }

    @Test func aReplyArrivesWithItsRootsPage() async throws {
        let (engine, store) = try Self.engine(pageSize: 3)
        #expect(try await engine.loadHistory(in: Self.space, until: Message.ID("h0-reply"), pageLimit: 20))
        #expect(try store.message(Message.ID("h0-reply"))?.isReply == true)
    }

    @Test func thePageLimitStopsIt() async throws {
        let (engine, store) = try Self.engine(pageSize: 3)
        #expect(try await engine.loadHistory(in: Self.space, until: Message.ID("h1"), pageLimit: 2) == false)
        #expect(try store.message(Message.ID("h1")) == nil)
    }

    @Test func aStoredMessageNeedsNoPage() async throws {
        let (engine, _) = try Self.engine(pageSize: 3)
        _ = try await engine.loadHistory(in: Self.space, until: Message.ID("h19"), pageLimit: 1)
        #expect(try await engine.loadHistory(in: Self.space, until: Message.ID("h19"), pageLimit: 0))
    }

    @Test func aMessageThatIsNotThereEndsWhenHistoryDoes() async throws {
        let (engine, _) = try Self.engine(pageSize: 3)
        #expect(try await engine
            .loadHistory(in: Self.space, until: Message.ID("absent"), pageLimit: 50) == false)
    }

    /// Review Focus 3: a canceled load writes nothing more.
    @Test func aCanceledLoadWritesNothing() async throws {
        let (engine, store) = try Self.engine(pageSize: 3)
        let task = Task {
            try await engine.loadHistory(in: Self.space, until: Message.ID("h1"), pageLimit: 20)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(try store.message(Message.ID("h1")) == nil)
        #expect(try store.messages(in: Self.space).isEmpty)
    }

    /// Review Focus 1: the real `LocalBridgeBackend.loadMessages(in:before:)`
    /// ignores `before:` and always answers the newest page, so this - not
    /// `thePageLimitStopsIt` - is the no-progress exit production actually
    /// takes. `h1` is never the newest page's oldest root, so the second call
    /// must give up rather than loop `pageLimit` times asking the same
    /// question.
    @Test func aBackendThatIgnoresTheCursorGivesUpRatherThanLooping() async throws {
        let store = try ChatStore.inMemory()
        let backend = RecordingBackend(world: Self.world, pageSize: 3)
        await backend.ignoreHistoryCursor(true)
        let engine = SyncEngine(backend: backend, store: store)
        #expect(try await engine.loadHistory(in: Self.space, until: Message.ID("h1"), pageLimit: 20) == false)
        #expect(await backend.loadMessagesCount <= 2)
        #expect(try store.message(Message.ID("h1")) == nil)
    }
}
