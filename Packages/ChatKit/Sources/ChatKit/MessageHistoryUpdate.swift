import Foundation

/// Fetched history, separate from a live arrival. Only a complete listing of
/// one explicit thread establishes that an absent server row was removed.
public struct MessageHistoryUpdate: Codable, Hashable, Sendable {
    public let messages: [Message]
    public let conversationID: Conversation.ID?
    public let threadID: MessageThread.ID?
    public let isComplete: Bool
    public let keepsReactions: Bool

    public init(
        messages: [Message], conversationID: Conversation.ID?, threadID: MessageThread.ID? = nil,
        isComplete: Bool = false, keepsReactions: Bool = false
    ) throws {
        guard !isComplete || threadID != nil,
              threadID == nil || conversationID != nil,
              conversationID != nil || keepsReactions,
              messages.allSatisfy({ message in
                  (conversationID == nil || message.conversationID == conversationID) &&
                      (threadID == nil || message.threadID == threadID)
              }) else { throw ChatError.unknown("History contains an invalid conversation or thread scope") }
        self.messages = messages
        self.conversationID = conversationID
        self.threadID = threadID
        self.isComplete = isComplete
        self.keepsReactions = keepsReactions
    }

    private enum CodingKeys: String, CodingKey {
        case messages, conversationID, threadID, isComplete, keepsReactions
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            messages: values.decode([Message].self, forKey: .messages),
            conversationID: values.decodeIfPresent(Conversation.ID.self, forKey: .conversationID),
            threadID: values.decodeIfPresent(MessageThread.ID.self, forKey: .threadID),
            isComplete: values.decodeIfPresent(Bool.self, forKey: .isComplete) ?? false,
            keepsReactions: values.decodeIfPresent(Bool.self, forKey: .keepsReactions) ?? false
        )
    }
}

/// Query methods on this backend commit world/history/followed-thread results
/// into the ordered replica stream before returning. Clients must not apply
/// those results again or run the provider's background reconciliation effects.
public protocol ProjectedChatBackend: CheckpointedChatBackend {}
