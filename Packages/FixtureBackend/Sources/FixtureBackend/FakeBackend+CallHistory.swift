import ChatKit

extension FakeBackend: CallHistoryBackend {
    public func callHistory(_ query: CallHistoryQuery = .init()) throws -> CallHistoryPage {
        try requireConnected()
        guard capabilities.canReadCallHistory else {
            throw ChatError.unsupported(capability: "callHistory")
        }
        let position = try CallHistoryPosition.decode(for: query)
        let rows = world.messages.filter { message in
            guard !message.isDeleted, message.callStatus != nil,
                  query.conversationID == nil || query.conversationID == message.conversationID
            else { return false }
            guard let position else { return true }
            let time = message.createdAt.timeIntervalSince1970
            return time < position.time || (time == position.time && message.id.rawValue < position.messageID)
        }.sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt > $1.createdAt
            }
            return $0.id.rawValue > $1.id.rawValue
        }
        let messages = Array(rows.prefix(query.limit))
        let next = rows.count > query.limit ? try messages.last.map {
            try CallHistoryPosition(message: $0, query: query).encoded()
        } : nil
        return CallHistoryPage(messages: messages, nextCursor: next)
    }
}
