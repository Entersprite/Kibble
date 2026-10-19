import ChatKit
import FixtureBackend
import Foundation
import GRDB
import Testing
@testable import ChatPersistence
@testable import SyncEngine

struct RemovedConversationRefreshTests {
    @Test(arguments: [false, true])
    func staleSnapshotsDoNotRestoreHideOrDeleteEvenAcrossStoreRecreation(_ deleted: Bool) throws {
        let database = try DatabaseQueue()
        let store = try ChatStore(database)
        let at = Date(timeIntervalSince1970: 2000)
        var conversation = Conversation(
            id: Conversation.ID("opaque"),
            kind: .directMessage,
            lastActivity: at,
            latestMainMessageAt: at
        )
        try store.apply([.upsertConversation(conversation), .removeConversation(
            conversation: conversation.id, historyBefore: deleted ? at : nil
        )])
        let reopenedStore = try ChatStore(database)
        try reopenedStore.apply([.replaceConversations([conversation]), .upsertConversation(conversation)])
        #expect(try reopenedStore.conversations().isEmpty)
        // Reply activity moves sidebar ordering but cannot reopen a removed chat.
        conversation.lastActivity = at.addingTimeInterval(100)
        try reopenedStore.apply([.replaceConversations([conversation])])
        #expect(try reopenedStore.conversations().isEmpty)
        conversation.latestMainMessageAt = at.addingTimeInterval(1)
        try reopenedStore.apply([.replaceConversations([conversation])])
        #expect(try reopenedStore.conversations().map(\.id) == [conversation.id])
        #expect(try reopenedStore.conversations().first?.historyClearedBefore == (deleted ? at : nil))
    }

    @Test func migrationKeepsExistingRemovalAndExplicitOpenKeepsItsCutoff() throws {
        let database = try DatabaseQueue()
        try Schema.migrator.migrate(database, upTo: "v15")
        try database.write { db in
            try db.execute(sql: """
            INSERT INTO conversationActionState (id, isRemoved, historyClearedBefore)
            VALUES ('opaque', 1, 2000)
            """)
        }
        let store = try ChatStore(database)
        let conversation = Conversation(id: Conversation.ID("opaque"), kind: .directMessage)
        try store.apply([.replaceConversations([conversation])])
        #expect(try store.conversations().isEmpty)
        try store.apply([.restoreConversation(conversation)])
        #expect(try store.conversations().first?.historyClearedBefore == Date(timeIntervalSince1970: 2000))
    }

    @Test func replayedMessagesAndRepliesCannotRestoreARemovedChat() throws {
        let store = try ChatStore.inMemory()
        let at = Date(timeIntervalSince1970: 2000)
        let conversation = Conversation(id: Conversation.ID("opaque"), kind: .directMessage, lastActivity: at)
        try store.apply([
            .upsertConversation(conversation),
            .removeConversation(conversation: conversation.id, historyBefore: at)
        ])
        var message = Message(
            id: Message.ID("m"),
            conversationID: conversation.id,
            threadID: MessageThread.ID("t"),
            sender: Member.ID("other"),
            text: "new",
            createdAt: at
        )
        #expect(try !store.restoreConversationForArrival(message))
        message.createdAt = at.addingTimeInterval(1)
        message.isReply = true
        #expect(try !store.restoreConversationForArrival(message))
        message.isReply = false
        #expect(try store.restoreConversationForArrival(message))
        try store.apply([.upsertConversation(conversation)])
        #expect(try store.conversations().count == 1)
    }
}
