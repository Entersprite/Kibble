import ChatKit
import GChatBridgeCore

extension ChannelEventMapping {
    static func messageLabelEvent(in body: ChannelEventBody) -> ChatEvent? {
        let decoded = PBLiteDecoder.decode(Event.EventBody.self, from: body.value)
        guard case let .messageLabelChanged(change)? = decoded.message.type,
              change.hasMessageID, change.hasLabel,
              !change.messageID.messageID.isEmpty,
              let conversation = conversationID(change.messageID.parentID.topicID.groupID)
        else { return nil }
        let thread = change.messageID.parentID.topicID.topicID
        switch change.label.labelType {
        case 2:
            return .messagePinsChanged(conversation)
        case 1 where !thread.isEmpty:
            return .messageStarChanged(
                address: MessageAddress(
                    conversation: conversation,
                    thread: .init(thread),
                    message: .init(change.messageID.messageID)
                ),
                starred: body.type == .messageLabelApplied
            )
        default:
            return nil
        }
    }
}
