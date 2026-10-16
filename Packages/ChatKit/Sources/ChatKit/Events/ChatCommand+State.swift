import Foundation

/// State-command decoding, shared by local and future remote backends.
extension ChatCommand {
    static func decodeStateCommand(
        _ tag: String,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> ChatCommand? {
        switch tag {
        case Tag.setTyping.rawValue:
            try .setTyping(
                conversationID: container.decode(
                    Conversation.ID.self, forKey: .conversationID
                ),
                threadID: container.decodeIfPresent(
                    MessageThread.ID.self, forKey: .threadID
                ),
                isTyping: container.decode(Bool.self, forKey: .isTyping)
            )
        case Tag.markRead.rawValue:
            try .markRead(
                conversationID: container.decode(
                    Conversation.ID.self, forKey: .conversationID
                ),
                upTo: container.decodeWire(Date.self, forKey: .upTo)
            )
        case Tag.setNotificationLevel.rawValue:
            try .setNotificationLevel(
                conversationID: container.decode(
                    Conversation.ID.self, forKey: .conversationID
                ),
                level: container.decode(NotificationLevel.self, forKey: .level)
            )
        case Tag.watchConversationActivity.rawValue:
            try .watchConversationActivity(
                conversationID: container.decodeIfPresent(Conversation.ID.self, forKey: .conversationID)
            )
        case Tag.watchPresence.rawValue:
            try .watchPresence(members: container.decode([Member.ID].self, forKey: .members))
        case Tag.loadMembers.rawValue:
            try .loadMembers(conversationID: container.decode(Conversation.ID.self, forKey: .conversationID))
        case Tag.setStatus.rawValue:
            try .setStatus(container.decodeIfPresent(MemberStatus.self, forKey: .status))
        case Tag.setAvailability.rawValue:
            try .setAvailability(container.decode(Availability.self, forKey: .availability))
        case Tag.reportActivity.rawValue:
            try .reportActivity(active: container.decode(Bool.self, forKey: .active))
        default:
            nil
        }
    }
}
