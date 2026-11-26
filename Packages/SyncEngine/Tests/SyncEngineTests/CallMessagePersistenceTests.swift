import ChatKit
import Foundation
import GRDB
import Testing
@testable import ChatPersistence
@testable import SyncEngine

struct CallMessagePersistenceTests {
    @Test func aPreCallSchemaMigratesWithoutClassifyingOrdinaryText() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v21")
        try queue.write { db in
            try db
                .execute(
                    sql: """
                    INSERT INTO conversation (id, kind, notificationLevel)
                    VALUES ('dm', 'directMessage', 'always')
                    """
                )
            try db.execute(sql: """
            INSERT INTO message (id, conversationID, threadID, sender, text, createdAt)
            VALUES ('message', 'dm', 'thread', 'peer', 'Call started', 1700000000)
            """)
        }
        let store = try ChatStore(queue)
        let message = try #require(try store.message(.init("message")))
        #expect(message.text == "Call started" && message.callStatus == nil)
    }

    @Test func callUpdatesSurviveStorageAndReopeningAndDeletionClearsTheStatus() throws {
        let queue = try DatabaseQueue()
        let store = try ChatStore(queue)
        let conversation = Conversation(id: .init("dm"), kind: .directMessage)
        var message = Message(
            id: .init("message"),
            conversationID: conversation.id,
            threadID: .init("thread"),
            sender: .init("peer"),
            text: "",
            createdAt: .distantPast,
            callStatus: .started
        )
        try store.apply([.upsertConversation(conversation), .upsertMessage(message)])
        #expect(try store.messages(in: conversation.id).first?.callStatus == .started)
        for status in [MessageCallStatus.ended, .unknown("future")] {
            message.callStatus = status
            try store.apply(SyncReducer.reduce(.messageUpdated(message)).writes)
            #expect(try ChatStore(queue).message(message.id)?.callStatus == status)
        }
        try store.apply([.markMessageDeleted(id: message.id, in: conversation.id)])
        let deleted = try #require(try store.message(message.id))
        #expect(deleted.isDeleted && deleted.callStatus == nil)
    }
}
