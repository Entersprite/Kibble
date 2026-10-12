import ChatKit
import Foundation
import GRDB
import Testing
@testable import SyncEngine

/// A write that touches only member rows must reach `model.directory`, which
/// `ChatSceneState` hands the views (meeting indicator spec §5). The store is
/// checked first, so "never written" and "written but never observed" fail
/// differently.
@Suite(.timeLimit(.minutes(1)))
struct DirectoryRefreshTests {
    private let alice = Member.ID("people/alice")

    /// A named bundle: swiftlint's `large_tuple` caps tuples at two.
    private struct Started {
        let model: ChatSessionModel
        let backend: FailingBackend
        let store: ChatStore
    }

    @MainActor
    private func started() async throws -> Started {
        let backend = FailingBackend()
        let store = try ChatStore.inMemory()
        try store.apply([.upsertMembers([Member(id: alice, kind: .human, displayName: "Alice")])])
        let model = ChatSessionModel(
            store: store, engine: SyncEngine(backend: backend, store: store), markReadDebounce: .zero
        )
        try await model.start()
        for _ in 0 ..< 500 where model.directory[alice] == nil {
            await Task.yield()
        }
        try #require(model.directory[alice] != nil)
        return Started(model: model, backend: backend, store: store)
    }

    @MainActor
    @Test func aCalendarChangeAloneReachesTheDirectory() async throws {
        let started = try await started()
        let (model, backend, store) = (started.model, started.backend, started.store)
        let schedule = CalendarSchedule(entries: [], validUntil: Date(timeIntervalSince1970: 1_790_000_000))
        await backend.emit(.calendarChanged(member: alice, schedule: schedule))
        for _ in 0 ..< 500 where (try? store.members().first?.calendar) == nil {
            await Task.yield()
        }
        try #require(try store.members().first?.calendar == schedule)
        for _ in 0 ..< 500 where model.directory[alice]?.calendar == nil {
            await Task.yield()
        }
        #expect(model.directory[alice]?.calendar == schedule)
        await model.stop()
    }

    /// Session 34's custom status rides the same path, and nothing tested it.
    @MainActor
    @Test func aStatusChangeAloneReachesTheDirectory() async throws {
        let started = try await started()
        let (model, backend, store) = (started.model, started.backend, started.store)
        let status = MemberStatus(emoji: "🌴")
        await backend.emit(.statusChanged(member: alice, status: status))
        for _ in 0 ..< 500 where (try? store.members().first?.status) == nil {
            await Task.yield()
        }
        try #require(try store.members().first?.status == status)
        for _ in 0 ..< 500 where model.directory[alice]?.status == nil {
            await Task.yield()
        }
        #expect(model.directory[alice]?.status == status)
        await model.stop()
    }

    /// A message write must not read the member table on the main thread.
    /// Until this test, every observation's delivery re-read the whole table
    /// synchronously and rebuilt `directory` (`refreshDirectory()`), and that
    /// read waited behind the store's serial queue: with history pages landing
    /// back to back, the main thread stalled for up to a quarter second at a
    /// time (session 66, measured on the session 58 store). `directory` is
    /// observed now, and the table is re-read only when a member changes.
    ///
    /// Counted at the connection with GRDB's statement trace, because an
    /// equal `directory` set notifies nobody (`@Observable` skips an
    /// `Equatable` value that did not change), so no observer can see the
    /// read. The member write at the end is the positive control: the same
    /// statement must run for it, or the trace saw nothing.
    @MainActor
    @Test func aMessageWriteDoesNotReadTheMemberTable() async throws {
        let started = try await started()
        let (model, store) = (started.model, started.store)
        let space = Conversation.ID("space/perf")
        model.select(space)
        for _ in 0 ..< 200 {
            await Task.yield()
        }

        let reads = StatementCounter()
        try await store.database.writeWithoutTransaction { db in
            db.trace(options: .statement) { event in
                guard case let .statement(statement) = event else { return }
                reads.record(statement.sql)
            }
        }
        let message = Message(
            id: Message.ID("perf-1"), conversationID: space, threadID: MessageThread.ID("perf-t1"),
            sender: alice, text: "a page of history", createdAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        try store.apply([.upsertMessage(message)])
        for _ in 0 ..< 500 where model.messages.isEmpty {
            await Task.yield()
        }
        try #require(model.messages.count == 1)
        for _ in 0 ..< 200 {
            await Task.yield()
        }
        #expect(
            reads.wholeMemberTable == 0,
            "a message write read the whole member table \(reads.wholeMemberTable) times"
        )

        let bob = Member.ID("people/bob")
        try store.apply([.upsertMembers([Member(id: bob, kind: .human, displayName: "Bob")])])
        for _ in 0 ..< 500 where model.directory[bob] == nil {
            await Task.yield()
        }
        try #require(model.directory[bob] != nil)
        #expect(reads.wholeMemberTable >= 1, "the positive control: a member write re-reads the table")
        try await store.database.writeWithoutTransaction { db in db.trace(options: .statement, nil) }
        await model.stop()
    }
}

/// Counts `SELECT ... FROM "member"` statements with no `WHERE`: the whole
/// table, which only the directory reads. Called from GRDB's trace, off the
/// main thread, so a lock.
private final class StatementCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var wholeMemberTable: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func record(_ sql: String) {
        guard sql.contains("FROM \"member\""), !sql.contains("WHERE") else { return }
        lock.lock()
        count += 1
        lock.unlock()
    }
}
