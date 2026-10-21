import Foundation

/// Directory coverage, separate from the rows returned by one provider read.
public struct ConversationSnapshot: Codable, Hashable, Sendable {
    public let conversations: [Conversation]
    public let isComplete: Bool
    public let removedIDs: Set<Conversation.ID>
    public let preservesDetails: Bool

    public init(
        conversations: [Conversation], isComplete: Bool = false,
        removedIDs: Set<Conversation.ID> = [], preservesDetails: Bool = false
    ) {
        self.conversations = conversations
        self.isComplete = isComplete
        self.removedIDs = removedIDs
        self.preservesDetails = preservesDetails
    }

    private enum CodingKeys: String, CodingKey {
        case conversations, isComplete, removedIDs, preservesDetails
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            conversations: values.decode([Conversation].self, forKey: .conversations),
            isComplete: values.decodeIfPresent(Bool.self, forKey: .isComplete) ?? false,
            removedIDs: values.decodeIfPresent(Set<Conversation.ID>.self, forKey: .removedIDs) ?? [],
            preservesDetails: values.decodeIfPresent(Bool.self, forKey: .preservesDetails) ?? false
        )
    }
}

public extension ChatBackend {
    /// Compatibility for providers whose existing directory contract is complete.
    func loadConversationSnapshot() async throws -> ConversationSnapshot {
        try await ConversationSnapshot(conversations: loadConversations(), isComplete: true)
    }
}
