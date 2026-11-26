import ChatKit
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

struct ResourceSyncStoreTests {
    @Test func unrelatedProgressDoesNotClearResourceFailure() throws {
        let store = try ChatStore.inMemory()
        let status = ResourceSyncStatus(resource: .directory, phase: .failed, error: .unknown("fixture"))
        try store.apply(SyncReducer.reduce(.resourceSyncChanged(status)).writes)
        try store.apply(SyncReducer.reduce(.connectionStateChanged(.connected)).writes)
        #expect(try store.resourceSyncStatuses() == [status])
        #expect(try store.lastError() == nil)
        try store.apply([.setResourceSyncStatus(.init(resource: .history, phase: .ready))])
        #expect(try store.resourceSyncStatuses() == [status])
        try store.apply([.setResourceSyncStatus(.init(resource: .directory, phase: .ready))])
        #expect(try store.resourceSyncStatuses().isEmpty)
    }

    @Test func lateClassificationPreservesCurrentFieldsAndCanSeedAMissingRow() throws {
        let store = try ChatStore.inMemory()
        var current = Conversation(id: .init("a"), kind: .directMessage, title: "Current")
        current.readPosition = Date(timeIntervalSince1970: 100)
        current.unreadCount = 0
        var stale = current
        stale.title = "Stale"; stale.readPosition = nil; stale.unreadCount = 10; stale
            .kind = .appDirectMessage
        try store.apply([.upsertConversation(current)])
        try store.apply(SyncReducer.reduce(.conversationClassified(stale)).writes)
        current.kind = .appDirectMessage
        #expect(try store.conversation(current.id) == current)
        stale.id = .init("b")
        try store.apply(SyncReducer.reduce(.conversationClassified(stale)).writes)
        #expect(try store.conversation(stale.id) == stale)
    }

    @Test func snapshotsIncludeHealthAndRequestedHistoryFromTheirCanonicalState() throws {
        let fixture = ReplicaHistoryTests()
        let store = try fixture.seeded()
        let status = ResourceSyncStatus(resource: .directory, phase: .failed)
        try store.apply([.setResourceSyncStatus(status)])
        let events = try store.readSnapshot(includingHistory: [
            fixture.conversation,
            .init("not-visible")
        ]) { _, events in
            events
        }
        #expect(events.contains(.resourceSyncChanged(status)))
        let histories = events.compactMap { event -> MessageHistoryUpdate? in
            guard case let .historyLoaded(update) = event else { return nil }
            return update
        }
        #expect(histories.count == 1)
        #expect(histories.first?.messages.count == 2)
        #expect(histories.first?.isComplete == false)
        let writes = [StoreWrite.invalidateReplicaHistory] + events.flatMap { SyncReducer.reduce($0).writes }
        try store.apply(writes)
        #expect(try store.messages(in: fixture.conversation).count == 1)
        #expect(try store.threadMessages(fixture.topic, in: fixture.conversation).count == 2)
        try store.apply([.clearEphemeralState])
        #expect(try store.resourceSyncStatuses().isEmpty)
    }
}
