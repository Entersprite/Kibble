import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// A write that touches only member rows must reach `model.directory`, which
/// `ChatSceneState` hands the views (meeting indicator spec §5). The store is
/// checked first, so "never written" and "written but never observed" fail
/// differently.
@Suite(.timeLimit(.minutes(1)))
struct DirectoryRefreshTests {
    private let alice = Member.ID("people/alice")

    @MainActor
    private func started() async throws -> (ChatSessionModel, FailingBackend, ChatStore) {
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
        return (model, backend, store)
    }

    @MainActor
    @Test func aCalendarChangeAloneReachesTheDirectory() async throws {
        let (model, backend, store) = try await started()
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
        let (model, backend, store) = try await started()
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
}
