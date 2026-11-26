import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ChatServiceStorage

struct ProviderOrderingTests {
    @Test func recoveryCannotOverwriteNewerServerEditsOrResurrectTombstones() throws {
        let storage = try SQLiteAccountStorage(account: .init("fixture"), path: ":memory:")
        var newer = ReconciliationBackend.message
        newer.text = "Newer"
        newer.editedAt = ReconciliationBackend.date.addingTimeInterval(20)
        _ = try storage.append(.messageUpdated(newer), live: true)
        var older = newer
        older.text = "Older"; older.editedAt = ReconciliationBackend.date.addingTimeInterval(10)
        let first = ProviderEventBatch(
            id: "stale",
            events: [.messageUpdated(older)],
            previousCheckpoint: nil,
            checkpoint: nil
        )
        #expect(try storage.appendProviderBatch(first, canonicalEvents: first.events).events.isEmpty)
        #expect(try storage.recentHistory(in: newer.conversationID, limit: 10).first?.text == "Newer")
        var deleted = newer; deleted.isDeleted = true
        let second = ProviderEventBatch(
            id: "deleted",
            events: [.messageUpdated(deleted)],
            previousCheckpoint: nil,
            checkpoint: nil
        )
        _ = try storage.appendProviderBatch(second, canonicalEvents: second.events)
        let third = ProviderEventBatch(
            id: "old-post",
            events: [.messageReceived(newer)],
            previousCheckpoint: nil,
            checkpoint: nil
        )
        #expect(try storage.appendProviderBatch(third, canonicalEvents: third.events).events.isEmpty)
        #expect(try storage.projection.message(newer.id)?.isDeleted == true)
    }

    @Test func explicitBackwardReadPositionsRemainValidMarkAsUnreadActions() throws {
        let storage = try SQLiteAccountStorage(account: .init("fixture"), path: ":memory:")
        let id = ReconciliationBackend.conversation
        _ = try storage.append(.conversationsChanged([Conversation(id: id, kind: .space)]), live: false)
        let newest = ReconciliationBackend.date.addingTimeInterval(20)
        let events: [ChatEvent] = [
            .readStateChanged(conversationID: id, lastReadAt: newest, unread: 0),
            .readStateChanged(
                conversationID: id,
                lastReadAt: ReconciliationBackend.date,
                unread: 2
            )
        ]
        let batch = ProviderEventBatch(id: "read", events: events, previousCheckpoint: nil, checkpoint: nil)
        let page = try storage.appendProviderBatch(batch, canonicalEvents: events)
        #expect(page.events.count == 2)
        #expect(try storage.conversation(id)?.readPosition == ReconciliationBackend.date)
        #expect(try storage.conversation(id)?.unreadCount == 2)
    }
}
