import ChatKit
import GChatBridgeCore

extension ChannelEventMapping {
    static func personalCollectionEvent(in body: ChannelEventBody) -> ChatEvent? {
        switch body.type {
        case .unsentMessageCreated, .unsentMessageDeleted, .unsentMessageUpdated:
            unsentMessageChange(in: body)
        case .messageLabelApplied, .messageLabelRemoved:
            messageLabelEvent(in: body)
        case .groupLabelApplied, .groupLabelRemoved, .rosterSectionCreated, .rosterSectionUpdated,
             .rosterSectionDeleted:
            conversationSectionChange(in: body)
        default:
            nil
        }
    }

    private static func conversationSectionChange(in body: ChannelEventBody) -> ChatEvent? {
        let decoded = PBLiteDecoder.decode(Event.EventBody.self, from: body.value)
        guard decoded.issues.allSatisfy({ $0.kind == .unknownField }) else { return nil }
        switch body.type {
        case .groupLabelApplied, .groupLabelRemoved:
            let change = decoded.message.groupLabelChanged
            guard ConversationSectionRequests.customLabelKey(change.label) != nil,
                  let id = conversationID(change.groupID) else { return nil }
            return .conversationSectionsChanged(conversationID: id)
        case .rosterSectionCreated, .rosterSectionUpdated, .rosterSectionDeleted:
            let change = decoded.message.rosterSectionChanged
            guard let id = ConversationSectionRequests.customSectionID(change.section.id) else { return nil }
            return .conversationSectionsChanged(removedSectionID: body
                .type == .rosterSectionDeleted ? id : nil)
        default:
            return nil
        }
    }
}
