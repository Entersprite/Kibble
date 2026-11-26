import ChatKit
import ChatService

extension SQLiteAccountStorage: ServiceMessagePinStorage {
    public func cachedMessagePins(in conversation: Conversation.ID) throws -> PinnedMessages? {
        try projection.cachedMessagePins(in: conversation)
    }
}
