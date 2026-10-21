import ChatKit
import Foundation
import Testing
@testable import ChatService

struct ProviderDirectoryTests {
    @Test func aDirectoryReadRetainsChangesAcceptedWhileItsResponseWasPending() async throws {
        let harness = try await ReconciliationHarness.make(checkpointing: true)
        try await authEventually { await harness.backend.acknowledgedBatches.contains("fixture-connected") }
        let row = Conversation(id: ReconciliationBackend.conversation, kind: .space, title: "Original")
        let initial = ProviderEventBatch(
            id: "initial",
            events: [],
            directory: .init(conversations: [row]),
            previousCheckpoint: nil,
            checkpoint: nil
        )
        await harness.backend.deliverBatch(initial)
        try await authEventually { await harness.backend.acknowledgedBatches.contains("initial") }
        let began = ProviderEventBatch(
            id: "began",
            events: [],
            directoryReadBegan: true,
            previousCheckpoint: nil,
            checkpoint: nil
        )
        await harness.backend.deliverBatch(began)
        try await authEventually { await harness.backend.acknowledgedBatches.contains("began") }
        let position = ReconciliationBackend.date
        _ = try harness.storage.append(
            .readStateChanged(conversationID: row.id, lastReadAt: position, unread: 0),
            live: false
        )
        var stale = row; stale.unreadCount = 7; stale.hasUnread = true
        let returned = ProviderEventBatch(
            id: "returned",
            events: [],
            directory: .init(conversations: [stale]),
            previousCheckpoint: nil,
            checkpoint: nil
        )
        await harness.backend.deliverBatch(returned)
        try await authEventually { await harness.backend.acknowledgedBatches.contains("returned") }
        #expect(try harness.storage.conversation(row.id)?.readPosition == position)
        #expect(try harness.storage.conversation(row.id)?.unreadCount == 0)
        await harness.service.shutdown()
    }
}
