import Foundation

public extension ChatBackend {
    func conversationEmail(_: Conversation.ID) async throws -> ConversationEmail {
        throw ChatError.unsupported(capability: "conversationEmail")
    }

    func openAppConversation(_: Member.ID, from _: Conversation.ID) async throws -> Conversation {
        throw ChatError.unsupported(capability: "conversationApps")
    }

    func searchConversationApps(_: String, in _: Conversation.ID) async throws -> [ConversationApp] {
        throw ChatError.unsupported(capability: "conversationApps")
    }

    func conversationIntegrations(_: Conversation.ID) async throws -> ConversationIntegrations {
        throw ChatError.unsupported(capability: "conversationWebhooks")
    }

    func webhookDeliveryURL(_: String, in _: Conversation.ID) async throws -> URL {
        throw ChatError.unsupported(capability: "conversationWebhooks")
    }

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

    func conversationPreview(_: Conversation.ID) async throws -> ConversationPreview {
        throw ChatError.unsupported(capability: "canPreviewConversations")
    }
}
