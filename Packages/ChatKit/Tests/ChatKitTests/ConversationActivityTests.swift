import Foundation
import Testing
@testable import ChatKit

struct ConversationActivityTests {
    private let conversation = Conversation.ID("conversation")
    private let me = Member.ID("me")
    private let other = Member.ID("other")

    @Test func receiptWireKeepsMicroseconds() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000.128263)
        let original = ReadPosition(member: other, readThrough: date)
        let bytes = try JSONEncoder().encode(original)
        let copy = try JSONDecoder().decode(ReadPosition.self, from: bytes)
        #expect(copy == original)
        #expect(String(decoding: bytes, as: UTF8.self).contains(".128263Z"))
    }

    @Test func scopedActivityRoundTripsAndUnknownPayloadSurvives() throws {
        let events: [ChatEvent] = [
            .scopedTypingChanged(TypingUpdate(
                conversationID: conversation,
                threadID: MessageThread.ID("reply"),
                member: other,
                isTyping: true,
                version: 42
            )),
            .readReceiptsChanged(ReadReceiptUpdate(
                conversationID: conversation,
                enabled: true,
                positions: [ReadPosition(
                    member: other,
                    readThrough: Date(timeIntervalSince1970: 100)
                )]
            ))
        ]
        for event in events {
            let bytes = try JSONEncoder().encode(event)
            #expect(try JSONDecoder().decode(ChatEvent.self, from: bytes) == event)
        }
        let unknown = Data(#"{"type":"futureActivity","extra":{"readers":[1,2]}}"#.utf8)
        let decoded = try JSONDecoder().decode(ChatEvent.self, from: unknown)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? NSDictionary
        #expect(try encoded == (JSONSerialization.jsonObject(with: unknown) as? NSDictionary))
    }

    @Test func markerUsesEqualityDeduplicatesAndExcludesSelfPendingDeletedAndReplies() throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000.128263)
        let message = Message(
            id: Message.ID("confirmed"),
            conversationID: conversation,
            threadID: MessageThread.ID("t"),
            sender: me,
            text: "Hello",
            createdAt: at
        )
        var pending = message
        pending.id = Message.ID("pending")
        var deleted = message
        deleted.id = Message.ID("deleted")
        deleted.isDeleted = true
        var reply = message
        reply.id = Message.ID("reply")
        reply.isReply = true
        let positions = [
            ReadPosition(member: other, readThrough: at),
            ReadPosition(member: other, readThrough: at.addingTimeInterval(-0.000_001)),
            ReadPosition(member: me, readThrough: at)
        ]
        let marker = try #require(ReadReceiptMarker.latest(
            in: [message, pending, deleted, reply],
            positions: positions,
            me: me,
            excluding: [pending.id]
        ))
        #expect(marker.messageID == message.id)
        #expect(marker.readers == [other])
        #expect(ReadReceiptMarker.latest(in: [message], positions: [positions[1]], me: me) == nil)
    }

    @Test func typingPrivacyIsIndependentAndOldSettingsDoNotPublish() throws {
        let old = try JSONDecoder().decode(NotificationRule.self, from: Data(#"{"readReceipts":true}"#.utf8))
        #expect(NotificationRule.resolve([old]).sharesTyping == false)
        let independent = NotificationRule(sharesTyping: true, readReceipts: false)
        let resolved = NotificationRule.resolve([independent])
        #expect(resolved.sharesTyping)
        #expect(!resolved.readReceipts)
        #expect(!independent.isEmpty)
        #expect(try JSONDecoder().decode(
            NotificationRule.self,
            from: JSONEncoder().encode(independent)
        ) == independent)
    }
}
