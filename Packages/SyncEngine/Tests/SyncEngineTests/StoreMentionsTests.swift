import ChatKit
import Foundation
import GRDB
import Testing
@testable import SyncEngine

struct StoreMentionsTests {
    private let conversation = Conversation(id: Conversation.ID("space/s"), kind: .space)

    @Test func mentionsSurviveTheStore() throws {
        let store = try ChatStore.inMemory()
        let message = Message(
            id: Message.ID("m:1"), conversationID: conversation.id, threadID: MessageThread.ID("t"),
            sender: Member.ID("users/alice"), text: "@Me hi",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            mentions: [Mention(target: .user(Member.ID("users/me")), start: 0, length: 3)]
        )
        try store.apply([.replaceConversations([conversation]), .upsertMessage(message)])
        #expect(try store.messages(in: conversation.id).first?.mentions == message.mentions)
    }

    /// Review Focus 1: a row as v3 wrote it - no `mentions` value - loads,
    /// with none.
    @Test func aRowWrittenBeforeMentionsReadsAsNone() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.replaceConversations([conversation])])
        try store.database.write { db in
            try db.execute(sql: """
            INSERT INTO message (id, conversationID, threadID, sender, text, createdAt, isDeleted,
                                 reactions, attachments)
            VALUES ('m:old', 'space/s', 't', 'users/alice', 'hi', ?, 0, '[]', '[]')
            """, arguments: [Date(timeIntervalSince1970: 1_790_000_000)])
        }
        #expect(try store.messages(in: conversation.id).first?.mentions == [])
    }
}
