import ChatKit
import Foundation
import GChatBridgeCore

enum ActivityMapping {
    static func event(_ body: ChannelEventBody) -> ChatEvent? {
        guard body.type == .typingStateChanged || body.type == .readReceiptChanged else { return nil }
        // High-field event bodies can be a dictionary without positional padding.
        let value = body.value.objectValue == nil ? body.value : PBLiteValue.array([body.value])
        let decoded = PBLiteDecoder.decode(Event.EventBody.self, from: value).message
        if body.type == .typingStateChanged, case let .typingStateChanged(event)? = decoded.type {
            return typing(event)
        }
        if body.type == .readReceiptChanged, case let .readReceiptChanged(event)? = decoded.type,
           let id = ChannelEventMapping.conversationID(event.groupID), event.hasReadReceiptSet {
            return .readReceiptsChanged(receipts(event.readReceiptSet, in: id))
        }
        return nil
    }

    static func typing(_ event: TypingStateChangedEvent) -> ChatEvent? {
        guard event.hasState, event.state == .typing || event.state == .stopped,
              !event.userID.id.isEmpty else { return nil }
        let group: GroupId
        let thread: MessageThread.ID?
        switch event.context.context {
        case let .groupID(value):
            group = value
            thread = nil
        case let .topicID(value):
            guard !value.topicID.isEmpty else { return nil }
            group = value.groupID
            thread = MessageThread.ID(value.topicID)
        case nil: return nil
        }
        guard let id = ChannelEventMapping.conversationID(group) else { return nil }
        return .scopedTypingChanged(TypingUpdate(
            conversationID: id, threadID: thread, member: ChatKit.Member.ID(event.userID.id),
            isTyping: event.state == .typing,
            version: event.hasStartTimestampUsec ? event.startTimestampUsec : nil
        ))
    }

    static func receipts(_ set: ReadReceiptSet, in id: Conversation.ID) -> ReadReceiptUpdate {
        let positions = set.readReceipts.compactMap { receipt -> ReadPosition? in
            guard !receipt.user.userID.id.isEmpty, receipt.hasReadTimeMicros,
                  receipt.readTimeMicros > 0 else { return nil }
            return ReadPosition(
                member: ChatKit.Member.ID(receipt.user.userID.id),
                readThrough: Microseconds.date(receipt.readTimeMicros)
            )
        }
        return ReadReceiptUpdate(
            conversationID: id,
            enabled: set.hasEnabled ? set.enabled : nil,
            positions: positions
        )
    }
}
