import Foundation

extension ChatEvent {
    static func decodeConversationActionEvent(
        _ tag: String, from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> ChatEvent? {
        switch tag {
        case Tag.meetingMetadataLoadingChanged.rawValue:
            try .meetingMetadataLoadingChanged(isLoading: container.decode(Bool.self, forKey: .isLoading))
        case Tag.meetingMetadataChanged.rawValue:
            try .meetingMetadataChanged(
                conversationID: container.decode(Conversation.ID.self, forKey: .conversationID),
                meeting: container.decodeIfPresent(MeetingOccurrence.self, forKey: .meeting)
            )
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
        case let .meetingMetadataLoadingChanged(isLoading):
            try container.encode(Tag.meetingMetadataLoadingChanged.rawValue, forKey: .type)
            try container.encode(isLoading, forKey: .isLoading)
        case let .meetingMetadataChanged(id, meeting):
            try container.encode(Tag.meetingMetadataChanged.rawValue, forKey: .type)
            try container.encode(id, forKey: .conversationID)
            try container.encode(meeting, forKey: .meeting)
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
