import Foundation

extension ChatEvent {
    static func decodeSynchronizationEvent(
        _ tag: String, from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> ChatEvent? {
        switch tag {
        case Tag.historyInvalidated.rawValue: .historyInvalidated
        case Tag.resourceSyncChanged.rawValue:
            try .resourceSyncChanged(container.decode(ResourceSyncStatus.self, forKey: .syncStatus))
        case Tag.conversationClassified.rawValue:
            try .conversationClassified(container.decode(Conversation.self, forKey: .conversation))
        default: nil
        }
    }

    func encodeSynchronizationEvent(into container: inout KeyedEncodingContainer<CodingKeys>) throws -> Bool {
        switch self {
        case .historyInvalidated:
            try container.encode(Tag.historyInvalidated.rawValue, forKey: .type)
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
