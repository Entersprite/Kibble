import ChatAPI
import ChatKit
import ChatServiceStorage
import Foundation
import Testing

struct ReplayPageBudgetTests {
    @Test func eventByteBudgetPagesBeforeTheTransportFrameLimit() throws {
        let storage = try SQLiteAccountStorage(account: ConnectedAccountID("account"), path: ":memory:")
        let start = try storage.checkpoint()
        let text = String(repeating: "x", count: 1_100_000)
        for index in 0 ..< 3 {
            var message = ReconciliationBackend.message
            message.id = Message.ID("large-\(index)")
            message.text = text
            _ = try storage.append(.messageReceived(message), live: true)
        }
        let first = try storage.readEvents(after: start, limit: 256)
        #expect(first.events.count == 1)
        #expect(first.hasMore)
        #expect(try ServiceCodec.encode(first).count < 4 * 1024 * 1024)
        let second = try storage.readEvents(after: first.checkpoint, limit: 256)
        #expect(second.events.count == 1)
        #expect(second.hasMore)
        let third = try storage.readEvents(after: second.checkpoint, limit: 256)
        #expect(third.events.count == 1)
        #expect(!third.hasMore)
    }
}
