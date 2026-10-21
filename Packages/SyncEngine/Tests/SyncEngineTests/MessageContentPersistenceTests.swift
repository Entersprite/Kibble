import ChatKit
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

struct MessageContentPersistenceTests {
    @Test func formattingAndQuotesPersistAndTombstonesClearThem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("messages.sqlite").path
        let store = try ChatStore.onDisk(at: path)
        var message = Message(
            id: Message.ID("m"), conversationID: Conversation.ID("c"), threadID: MessageThread.ID("t"),
            sender: Member.ID("s"), text: "formatted", createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        message.content = MessageContent(
            formatting: [MessageFormat(style: "bold", start: 0, length: 9)],
            quote: MessageQuote(message: message),
            forwarded: ForwardedMessage(source: MessageQuote(message: message), senderName: "Alex Example")
        )
        try store.apply([.upsertMessage(message)])
        let reopened = try ChatStore.onDisk(at: path)
        #expect(try reopened.message(message.id)?.content == message.content)
        var updated = message
        updated.content?.formatting = [MessageFormat(style: "future", start: 0, length: 9)]
        try reopened.apply([.upsertMessageKeepingReactions(updated)])
        #expect(try reopened.message(message.id)?.content == updated.content)
        try reopened.apply([.markMessageDeleted(id: message.id, in: message.conversationID)])
        #expect(try reopened.message(message.id)?.content == nil)
    }
}
