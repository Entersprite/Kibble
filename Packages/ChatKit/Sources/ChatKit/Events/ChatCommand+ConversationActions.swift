import Foundation

extension ChatCommand {
    static func decodeConversationAction(
        _ tag: String, from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> ChatCommand? {
        guard tag == Tag.conversationAction.rawValue else { return nil }
        return try .conversationAction(
            conversationID: container.decode(Conversation.ID.self, forKey: .conversationID),
            action: container.decode(ConversationAction.self, forKey: .action)
        )
    }

    func encodeConversationAction(into container: inout KeyedEncodingContainer<CodingKeys>) throws -> Bool {
        guard case let .conversationAction(id, action) = self else { return false }
        try container.encode(Tag.conversationAction.rawValue, forKey: .type)
        try container.encode(id, forKey: .conversationID)
        try container.encode(action, forKey: .action)
        return true
    }
}
