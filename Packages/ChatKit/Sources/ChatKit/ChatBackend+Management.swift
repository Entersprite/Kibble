import Foundation

public extension ChatBackend {
    func createConversation(_: ConversationDraft) async throws -> ConversationCreationResult {
        throw ChatError.unsupported(capability: "canCreateConversations")
    }

    func mutateConversation(
        _: ConversationMutation,
        in _: Conversation.ID,
        operationID _: String,
        expectedRevision _: String?
    ) async throws
        -> ConversationMutationResult {
        throw ChatError.unsupported(capability: "canReadConversationDetails")
    }

    func conversationDetails(_: Conversation.ID) async throws -> ConversationDetails {
        throw ChatError.unsupported(capability: "canReadConversationDetails")
    }

    func participants(in _: Conversation.ID, after _: String?) async throws -> ConversationParticipantPage {
        throw ChatError.unsupported(capability: "canReadConversationDetails")
    }

    func browseSpaces(_: SpaceDirectoryQuery, after _: String?) async throws -> SpaceDirectoryPage {
        throw ChatError.unsupported(capability: "canBrowseSpaces")
    }
}
