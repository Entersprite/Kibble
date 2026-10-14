import ChatKit
import Foundation
import GRDB
import Testing
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1)))
struct NoOpObservationTests {
    private struct WriterScheduler: ValueObservationScheduler {
        func immediateInitialValue() -> Bool {
            false
        }

        func schedule(_ action: @escaping @Sendable () -> Void) {
            action()
        }
    }

    @Test func anUnchangedHistoryPageDoesNotRerunTranscriptQueries() async throws {
        let store = try ChatStore.inMemory()
        let message = Message(
            id: Message.ID("message/noop"), conversationID: Conversation.ID("space/noop"),
            threadID: MessageThread.ID("thread/noop"), sender: Member.ID("member/noop"),
            text: "hello", createdAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        try store.apply([.upsertMessage(message)])
        let reads = QueryCounter()
        var observer = ValueObservation.tracking { db in
            reads.increment()
            return try String.fetchAll(db, sql: "SELECT text FROM message ORDER BY id")
        }.snapshotValues(in: store.database, scheduling: WriterScheduler()).makeAsyncIterator()
        let initial = try await observer.next()
        #expect(initial == ["hello"])
        #expect(reads.value == 1)
        for _ in 0 ..< 10 {
            try store.apply([.upsertMessage(message)])
        }
        #expect(reads.value == 1)
        var changed = message
        changed.text = "new content"
        try store.apply([.upsertMessage(changed)])
        let afterEdit = try await observer.next()
        #expect(afterEdit == ["new content"])
        #expect(reads.value == 2, "positive control: a real content change re-runs the query")
    }
}

private final class QueryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
