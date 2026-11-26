import ChatKit
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

struct ConversationActivityStoreTests {
    private let conversation = Conversation(id: Conversation.ID("conversation"), kind: .directMessage)
    private let reader = Member.ID("reader")
    private let precise = Date(timeIntervalSince1970: 1_790_000_000.128263)

    @Test func receiptsKeepMicrosecondsAndNeverMoveBackwardOrChangeUnreadState() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.replaceConversations([conversation])])
        let before = try store.conversations()
        try store.apply([.setReadReceipts(ReadReceiptUpdate(
            conversationID: conversation.id,
            enabled: true,
            positions: [ReadPosition(
                member: reader,
                readThrough: precise
            )]
        ))])
        try store.apply([.setReadReceipts(ReadReceiptUpdate(
            conversationID: conversation.id,
            positions: [ReadPosition(
                member: reader,
                readThrough: precise
                    .addingTimeInterval(-0.000_001)
            )]
        ))])
        let activity = try store.activity(in: conversation.id)
        #expect(activity.receiptsEnabled == true)
        #expect(activity.receipts.count == 1)
        #expect(activity.receipts.first?.readThrough == precise)
        #expect(try store.conversations() == before)
        try store.apply([.setReadReceipts(ReadReceiptUpdate(conversationID: conversation.id, positions: []))])
        #expect(try store.activity(in: conversation.id) == activity)
    }

    @Test func disableAndSessionResetRemoveClaims() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.setReadReceipts(ReadReceiptUpdate(
            conversationID: conversation.id,
            enabled: true,
            positions: [ReadPosition(
                member: reader,
                readThrough: precise
            )]
        ))])
        try store.apply([.setReadReceipts(ReadReceiptUpdate(
            conversationID: conversation.id,
            enabled: false,
            positions: []
        ))])
        #expect(try store.activity(in: conversation.id).receipts.isEmpty)
        try store.apply([.setReadReceipts(ReadReceiptUpdate(
            conversationID: conversation.id,
            positions: [ReadPosition(
                member: reader,
                readThrough: precise
            )]
        ))])
        #expect(try store.activity(in: conversation.id).receipts.isEmpty)
        try store.apply([.clearEphemeralState])
        #expect(try store.activity(in: conversation.id) == ConversationActivity())
    }

    @Test func typingScopesAndOlderStopsAreIsolated() throws {
        let store = try ChatStore.inMemory()
        let main = TypingUpdate(conversationID: conversation.id, member: reader, isTyping: true, version: 20)
        var thread = main
        thread.threadID = MessageThread.ID("thread")
        try store.apply([.setScopedTyping(main), .setScopedTyping(thread)])
        var oldStop = main
        oldStop.version = 19
        oldStop.isTyping = false
        try store.apply([.setScopedTyping(oldStop)])
        #expect(try store.activity(in: conversation.id).typing.count == 2)
        oldStop.version = 20
        try store.apply([.setScopedTyping(oldStop)])
        #expect(try store.activity(in: conversation.id).typing == [thread])
        var oldStart = main
        oldStart.version = 19
        try store.apply([.setScopedTyping(oldStart)])
        #expect(try store.activity(in: conversation.id).typing == [thread])
        try store.apply([.clearActivityTyping])
        #expect(try store.activity(in: conversation.id).typing.isEmpty)
    }
}
