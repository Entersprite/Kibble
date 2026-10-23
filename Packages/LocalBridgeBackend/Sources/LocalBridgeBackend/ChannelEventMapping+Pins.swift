import ChatKit
import GChatBridgeCore

extension ChannelEventMapping {
    static func pinEvent(in body: ChannelEventBody) -> ChatEvent? {
        guard body.type == .messageLabelApplied || body.type == .messageLabelRemoved else { return nil }
        let decoded = PBLiteDecoder.decode(Event.EventBody.self, from: body.value)
        guard case let .messageLabelChanged(change)? = decoded.message.type,
              change.hasMessageID, change.label.labelType == 2,
              !change.messageID.messageID.isEmpty,
              let conversation = conversationID(change.messageID.parentID.topicID.groupID)
        else { return nil }
        return .messagePinsChanged(conversation)
    }
}
