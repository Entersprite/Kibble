import Foundation

extension ChatEvent {
    static func decodeSynchronizationEvent(
        _ tag: String, from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> ChatEvent? {
        switch tag {
        case Tag.messagePinsLoaded.rawValue:
            try .messagePinsLoaded(
                conversationID: container.decode(Conversation.ID.self, forKey: .conversationID),
                pins: container.decode(PinnedMessages.self, forKey: .pins)
            )
        case Tag.messagePinsChanged.rawValue:
            try .messagePinsChanged(container.decode(Conversation.ID.self, forKey: .conversationID))
        case Tag.historyInvalidated.rawValue:
            try container.decodeIfPresent([Conversation.ID].self, forKey: .conversationIDs)
                .map(ChatEvent.conversationHistoryInvalidated) ?? .historyInvalidated
        case Tag.resourceSyncChanged.rawValue:
            try .resourceSyncChanged(container.decode(ResourceSyncStatus.self, forKey: .syncStatus))
        case Tag.conversationClassified.rawValue:
            try .conversationClassified(container.decode(Conversation.self, forKey: .conversation))
        default: nil
        }
    }

    func encodeSynchronizationEvent(into container: inout KeyedEncodingContainer<CodingKeys>) throws -> Bool {
        switch self {
        case let .messagePinsLoaded(conversation, pins):
            try container.encode(Tag.messagePinsLoaded.rawValue, forKey: .type)
            try container.encode(conversation, forKey: .conversationID)
            try container.encode(pins, forKey: .pins)
        case let .messagePinsChanged(conversation):
            try container.encode(Tag.messagePinsChanged.rawValue, forKey: .type)
            try container.encode(conversation, forKey: .conversationID)
        case .historyInvalidated:
            try container.encode(Tag.historyInvalidated.rawValue, forKey: .type)
        case let .conversationHistoryInvalidated(ids):
            try container.encode(Tag.historyInvalidated.rawValue, forKey: .type)
            try container.encode(ids, forKey: .conversationIDs)
        case let .resourceSyncChanged(status):
            try container.encode(Tag.resourceSyncChanged.rawValue, forKey: .type)
            try container.encode(status, forKey: .syncStatus)
        case let .conversationClassified(row):
            try container.encode(Tag.conversationClassified.rawValue, forKey: .type)
            try container.encode(row, forKey: .conversation)
        default: return false
        }
        return true
    }
}
