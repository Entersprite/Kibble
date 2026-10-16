import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct ActivityMappingTests {
    @Test func channelDispatchUsesTheEventTagAndActualBodyField() throws {
        let typing = #"{"12":29,"26":[1,["reader"],[[null,null,["dm"]]],"100"]}"#
        let body = try ChannelEventBody(typeTag: 29, value: PBLiteValue(json: Data(typing.utf8)))
        let result = ChannelEventMapping.chatEvents(from: ChannelEvent(bodies: [body]))
        guard case let .scopedTypingChanged(update)? = result.first else {
            Issue.record("Ordinary channel did not route typing"); return
        }
        #expect(update.conversationID == Conversation.ID("dm/dm"))
        #expect(update.version == 100)
        let wrongTag = ChannelEventBody(typeTag: 36, value: body.value)
        guard case .unknown? = ChannelEventMapping.chatEvents(from: ChannelEvent(bodies: [wrongTag])).first
        else {
            Issue.record("A mismatched event tag must stay unknown"); return
        }
        let receipts = #"{"12":36,"33":[[null,null,["dm"]],[true,[[null,"1790000000128263",[["reader"]]]]]]}"#
        let receiptBody = try ChannelEventBody(typeTag: 36, value: PBLiteValue(json: Data(receipts.utf8)))
        let receiptResult = ChannelEventMapping.chatEvents(from: ChannelEvent(bodies: [receiptBody]))
        guard case let .readReceiptsChanged(receipt)? = receiptResult.first else {
            Issue.record("Ordinary channel did not route receipts"); return
        }
        #expect(receipt.enabled == true)
        #expect(receipt.positions.count == 1)
    }

    @Test func groupAndTopicTypingPreserveExactContexts() throws {
        var event = TypingStateChangedEvent()
        event.state = .typing
        event.userID.id = "reader"
        event.context.groupID.dmID.dmID = "dm"
        let main = try #require(ActivityMapping.typing(event))
        guard case let .scopedTypingChanged(update) = main
        else { Issue.record("Missing typing event"); return }
        #expect(update.threadID == nil)
        #expect(update.member == ChatKit.Member.ID("reader"))
        event.context.topicID.groupID.dmID.dmID = "dm"
        event.context.topicID.topicID = "thread"
        let scoped = try #require(ActivityMapping.typing(event))
        guard case let .scopedTypingChanged(thread) = scoped
        else { Issue.record("Missing thread event"); return }
        #expect(thread.threadID == MessageThread.ID("thread"))
        event.userID.id = ""
        #expect(ActivityMapping.typing(event) == nil)
    }

    @Test func receiptPresenceIsNotConfusedWithFalseOrZero() {
        let id = Conversation.ID("conversation")
        var set = ReadReceiptSet()
        #expect(ActivityMapping.receipts(set, in: id).enabled == nil)
        set.enabled = false
        #expect(ActivityMapping.receipts(set, in: id).enabled == false)
        var receipt = ReadReceipt()
        receipt.user.userID.id = "reader"
        set.readReceipts = [receipt]
        #expect(ActivityMapping.receipts(set, in: id).positions.isEmpty)
        receipt.readTimeMicros = 1_790_000_000_128_263
        set.readReceipts = [receipt]
        let position = ActivityMapping.receipts(set, in: id).positions.first
        #expect(position?.readThrough == Date(timeIntervalSince1970: 1_790_000_000.128263))
    }

    @Test func typingRequestUsesGroupOrTopicAndHeader() {
        var group = GroupId()
        group.dmID.dmID = "dm"
        let main = TypingRequests.make(group: group, topic: nil, typing: true)
        #expect(main.hasRequestHeader)
        #expect(main.context.groupID == group)
        #expect(main.state == .typing)
        let thread = TypingRequests.make(group: group, topic: "thread", typing: false)
        #expect(thread.context.topicID.groupID == group)
        #expect(thread.context.topicID.topicID == "thread")
        #expect(thread.state == .stopped)
    }
}
