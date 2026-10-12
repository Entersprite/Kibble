import Foundation

extension ChatEvent {
    static func decodeConversationActionEvent(
        _ tag: String, from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> ChatEvent? {
        switch tag {
        case Tag.conversationRemoved.rawValue:
            try .conversationRemoved(
                conversationID: container.decode(Conversation.ID.self, forKey: .conversationID),
                historyBefore: container.decodeWireIfPresent(Date.self, forKey: .historyBefore)
            )
        case Tag.conversationUnreadMarkChanged.rawValue:
            try .conversationUnreadMarkChanged(
                conversationID: container.decode(Conversation.ID.self, forKey: .conversationID),
                at: container.decodeWireIfPresent(Date.self, forKey: .at)
            )
        default: nil
        }
    }

    func encodeConversationActionEvent(into container: inout KeyedEncodingContainer<CodingKeys>) throws
        -> Bool {
        switch self {
        case let .conversationRemoved(id, before):
            try container.encode(Tag.conversationRemoved.rawValue, forKey: .type)
            try container.encode(id, forKey: .conversationID)
            try container.encodeWireIfPresent(before, forKey: .historyBefore)
        case let .conversationUnreadMarkChanged(id, at):
            try container.encode(Tag.conversationUnreadMarkChanged.rawValue, forKey: .type)
            try container.encode(id, forKey: .conversationID)
            try container.encodeWireIfPresent(at, forKey: .at)
        default: return false
        }
        return true
    }
}
