import ChatKit
import Foundation
import Testing
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1)))
struct HistoryReconciliationTests {
    private let conversation = Conversation.ID("space/example")
    private let sender = Member.ID("user/example")
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func root(_ id: String, minute: Int) -> Message {
        Message(
            id: Message.ID(id), conversationID: conversation,
            threadID: MessageThread.ID("thread/\(id)"), sender: sender,
            text: id, createdAt: start.addingTimeInterval(Double(minute * 60))
        )
    }

    @Test func aMissingCachedRootIsRemovedOnlyAfterItsCompleteTopicOmitsIt() async throws {
        let backend = RecordingBackend()
        let oldest = root("oldest", minute: 1)
        let stale = root("stale", minute: 2)
        let newest = root("newest", minute: 3)
        let outside = root("outside", minute: 0)
        let local = root("local/pending", minute: 2)
        await backend.answerHistory(in: conversation, with: [oldest, newest])
        await backend.answerThread(stale.threadID, with: [], complete: true)
        let store = try ChatStore.inMemory()
        try store.apply([stale, outside, local].map { .upsertMessage($0) })

        try await SyncEngine(backend: backend, store: store).loadMoreMessages(
            in: conversation, verifyCachedRoots: true
        )

        #expect(try store.message(stale.id) == nil)
        #expect(try store.message(outside.id) != nil)
        #expect(try store.message(local.id) != nil)
        #expect(try store.message(newest.id) != nil)
    }

    @Test func anIncompleteDirectListingCannotRemoveACachedRoot() async throws {
        let backend = RecordingBackend()
        let oldest = root("oldest", minute: 1)
        let cached = root("cached", minute: 2)
        let newest = root("newest", minute: 3)
        await backend.answerHistory(in: conversation, with: [oldest, newest])
        await backend.answerThread(cached.threadID, with: [])
        let store = try ChatStore.inMemory()
        try store.apply([.upsertMessage(cached)])

        try await SyncEngine(backend: backend, store: store).loadMoreMessages(
            in: conversation, verifyCachedRoots: true
        )

        #expect(try store.message(cached.id) != nil)
    }
}
