import ChatKit
import GChatBridgeCore

extension ChannelEventMapping {
    static func unsentMessageChange(in body: ChannelEventBody) -> ChatEvent {
        let decoded = PBLiteDecoder.decode(Event.EventBody.self, from: body.value)
        let message = decoded.message.unsentMessageChanged.message
        let address = UnsentMessageMapping.address(message.id)
        switch message.unsentType {
        case 1:
            // Updating a draft into a schedule only supplies its new type.
            return .unsentMessagesChanged(.init(
                address: address,
                drafts: body.type == .unsentMessageUpdated,
                scheduled: true
            ))
        case 2:
            return .unsentMessagesChanged(.init(address: address, drafts: true, scheduled: false))
        default:
            // A deletion can carry only its original identity.
            return .unsentMessagesChanged(.init(address: address, drafts: true, scheduled: true))
        }
    }
}
