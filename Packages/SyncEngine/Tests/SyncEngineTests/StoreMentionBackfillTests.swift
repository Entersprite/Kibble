import ChatKit
import Foundation
import GRDB
import Testing
@testable import SyncEngine

/// The backfill's status, in the store (ruling 5): written by the runner,
/// observed by the pane, and a claim about *now* like `connectionState`.
@Suite(.timeLimit(.minutes(1)))
struct StoreMentionBackfillTests {
    @Test func aWrittenStatusIsReadAndObserved() async throws {
        let store = try ChatStore.inMemory()
        var iterator = store.observeMentionBackfill().makeAsyncIterator()
        #expect(try await iterator.next() == MentionBackfillStatus())
        try store.apply([.setMentionBackfill(MentionBackfillStatus(running: false, failedConversations: 3))])
        #expect(try await iterator.next() == MentionBackfillStatus(running: false, failedConversations: 3))
        #expect(try store.mentionBackfill() == MentionBackfillStatus(running: false, failedConversations: 3))
    }

    /// A fresh process has not started a run, whatever the file last said.
    @Test func clearingEphemeralStateResetsIt() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.setMentionBackfill(MentionBackfillStatus(running: true, failedConversations: 2))])
        try store.apply([.clearEphemeralState])
        #expect(try store.mentionBackfill() == MentionBackfillStatus())
    }

    /// A store from before v7 reads as "not searching, nothing failed".
    @Test func aStoreFromBeforeV7ReadsAsNotSearching() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v6")
        let store = try ChatStore(queue)
        #expect(try store.mentionBackfill() == MentionBackfillStatus())
    }
}
