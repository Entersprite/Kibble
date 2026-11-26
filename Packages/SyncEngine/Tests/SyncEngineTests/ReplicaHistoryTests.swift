import ChatKit
import FixtureBackend
import Foundation
import GRDB
import Testing
@testable import ChatPersistence
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1)))
struct ReplicaHistoryTests {
    let conversation = Conversation.ID("replica-chat")
    let topic = MessageThread.ID("topic")
    let me = Member.ID("self")

    func message(_ index: Int, reply: Bool = false) -> Message {
        Message(
            id: Message.ID("row-\(index)"), conversationID: conversation, threadID: topic,
            sender: Member.ID("other"), text: "@Me message \(index)",
            createdAt: Date(timeIntervalSince1970: Double(index)),
            mentions: [Mention(target: .user(me), start: 0, length: 3)], isReply: reply
        )
    }

    func seeded() throws -> ChatStore {
        let store = try ChatStore.inMemory()
        try store.apply([
            .setLocalMember(me), .replaceConversations([Conversation(id: conversation, kind: .space)]),
            .upsertMessage(message(1)), .upsertMessage(message(2, reply: true)),
            .applyThreadChange(thread: topic, conversation: conversation, change: .followed(true))
        ])
        return store
    }

    @Test func replacementHidesAllCachedBodiesWithoutErasingThem() async throws {
        let store = try seeded()
        #expect(try store.followedThreads(limit: 10).count == 1)
        #expect(try store.unreadMentionCount() == 2)
        try store.apply([.invalidateReplicaHistory])
        #expect(try store.messages(in: conversation).isEmpty)
        #expect(try store.message(message(1).id) == nil)
        #expect(try store.threadMessages(topic, in: conversation).isEmpty)
        #expect(try store.mentionsOfMe().isEmpty)
        #expect(try store.unreadMentionCount() == 0)
        #expect(try store.followedThreads(limit: 10).isEmpty)
        #expect(try await store.transcriptWindow(in: conversation, request: .latest(100)).messages.isEmpty)
        #expect(try await store.meetingTranscript(
            occurrences: [conversation], request: .latest(100)
        ).messages.isEmpty)
        let retained = try await store.database.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM message")
        }
        #expect(retained == 2)
        // An unchanged authoritative page still verifies its own rows only.
        try store.apply([.upsertMessage(message(1))])
        #expect(try store.messages(in: conversation).map(\.id) == [message(1).id])
        #expect(try store.threadMessages(topic, in: conversation).map(\.id) == [message(1).id])
        #expect(try store.mentionsOfMe().map(\.message.id) == [message(1).id])
    }

    @Test func partialSearchHitCannotReviveAnOldStoredBody() throws {
        let store = try seeded()
        try store.apply([.invalidateReplicaHistory, .insertMessageIfAbsent(message(1))])
        #expect(try store.message(message(1).id) == nil)
        try store.apply([.insertMessageIfAbsent(message(3))])
        #expect(try store.messages(in: conversation).map(\.id) == [message(3).id])
        try store.apply([.markMessageDeleted(id: message(2).id, in: conversation)])
        #expect(try store.message(message(2).id)?.isDeleted == true)
        #expect(try store.message(message(2).id)?.text == "")
    }

    @Test func pendingRowsSurviveResetAndCanonicalIdentityRetiresTracking() throws {
        let store = try seeded()
        var pending = message(3)
        pending.localID = "send-original"
        // No provider-ID spelling or prefix assumption is needed for retention.
        try store.apply([.upsertMessage(pending), .beginMessageDelivery(pending.id)])
        try store.apply([.setMessageDelivery(pending.id, .sent), .invalidateReplicaHistory])
        #expect(try store.messages(in: conversation).map(\.id) == [pending.id])
        #expect(try store.messageDeliveries().first?.status == .sent)
        try store.apply([.upsertMessage(pending)])
        #expect(try store.messageDeliveries().isEmpty)
        #expect(try store.message(pending.id) == pending)
        try store.apply([.invalidateReplicaHistory])
        #expect(try store.messages(in: conversation).isEmpty)
    }

    @Test func snapshotCheckpointAndHistoryConfidenceCommitTogetherOnlyOnce() async throws {
        let store = try seeded()
        let backend = FakeBackend(world: .minimal)
        let engine = SyncEngine(backend: backend, store: store)
        let first = ReplicaCheckpoint(account: "account", stream: "original", sequence: 1)
        _ = try store.applyCheckpointed([], checkpoint: first)
        let next = ReplicaCheckpoint(account: "account", stream: "replacement", sequence: 2)
        let delivery = ChatDelivery(checkpoint: next, events: [], isSnapshot: true, isLive: false)
        try await store.database.write { db in
            try db.execute(sql: """
            CREATE TRIGGER failCheckpoint BEFORE UPDATE ON replicaCheckpoint
            BEGIN SELECT RAISE(ABORT, 'checkpoint refused'); END;
            """)
        }
        #expect(await !engine.handleDelivery(delivery))
        #expect(try store.replicaHistoryEpoch() == 0)
        #expect(try store.replicaCheckpoint() == first)
        #expect(try store.messages(in: conversation).count == 1)
        try await store.database.write { db in try db.execute(sql: "DROP TRIGGER failCheckpoint") }
        #expect(await engine.handleDelivery(delivery))
        #expect(try store.replicaHistoryEpoch() == 1)
        #expect(try store.messages(in: conversation).isEmpty)
        try store.apply([.upsertMessage(message(1))])
        #expect(await engine.handleDelivery(delivery))
        #expect(try store.replicaHistoryEpoch() == 1)
        #expect(try store.message(message(1).id) != nil)
    }

    @Test func replacementNeverAnnouncesReplayAsFreshArrival() async throws {
        let store = try seeded()
        let engine = SyncEngine(backend: FakeBackend(world: .minimal), store: store)
        let replay = message(3)
        let live = message(4)
        #expect(await engine.handleDelivery(ChatDelivery(
            checkpoint: ReplicaCheckpoint(account: "account", stream: "replacement", sequence: 1),
            events: [.messageReceived(replay)], isSnapshot: true, isLive: true
        )))
        #expect(try store.message(replay.id) == replay)
        #expect(await engine.handleDelivery(ChatDelivery(
            checkpoint: ReplicaCheckpoint(account: "account", stream: "replacement", sequence: 2),
            events: [.messageReceived(live)], isSnapshot: false, isLive: true
        )))
        #expect(await firstAnnouncement(of: engine) == .arrived(live))
    }

    @Test func exhaustedEpochRefusesAtomicallyRatherThanMakingOldHistoryCurrent() async throws {
        let store = try seeded()
        try await store.database.write { db in
            try db.execute(sql: "UPDATE replicaHistory SET epoch = ?", arguments: [Int64.max])
        }
        let checkpoint = ReplicaCheckpoint(account: "account", stream: "stream", sequence: 1)
        #expect(throws: (any Error).self) {
            try store.applyCheckpointed([.invalidateReplicaHistory], checkpoint: checkpoint)
        }
        #expect(try store.replicaCheckpoint() == nil)
        #expect(try store.replicaHistoryEpoch() == Int64.max)
        #expect(try store.messages(in: conversation).isEmpty)
    }

    @Test func currentWindowUsesIndexedHistoryAndBoundedPendingAtRealisticSize() async throws {
        let store = try ChatStore.inMemory()
        try store.apply((0 ..< 10000).map { .upsertMessage(message($0)) })
        try store.apply([.invalidateReplicaHistory])
        try store.apply((10000 ..< 10512).flatMap { index -> [StoreWrite] in
            var pending = message(index)
            pending.localID = "operation-\(index)"
            return [.upsertMessage(pending), .beginMessageDelivery(pending.id)]
        })
        try store.apply([.invalidateReplicaHistory, .upsertMessage(message(9999))])
        let details = try await store.database.read { db in
            try Row.fetchAll(db, sql: """
            EXPLAIN QUERY PLAN SELECT * FROM currentMessage
            WHERE conversationID = ? AND isReply = 0 ORDER BY createdAt DESC, id DESC LIMIT 100
            """, arguments: [conversation.rawValue]).map { $0["detail"] as String }.joined(separator: "\n")
        }
        #expect(details.contains("message_conversation_epoch_created"))
        #expect(!details.contains("SCAN message\n"))
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0 ..< 20 {
            let window = try await store.transcriptWindow(in: conversation, request: .latest(100))
            #expect(window.messages.count == 100)
            #expect(window.messages.first?.id == message(10412).id)
        }
        #expect(start.duration(to: clock.now) < .seconds(5))
        print(
            "Indexed history, 10k retained/512 pending, 20 windows: \(start.duration(to: clock.now))"
        )
    }
}
