import ChatAPI
import ChatKit
import Foundation

public extension ServiceBackend {
    func openDirectConversation(with member: Member.ID) async throws -> Conversation {
        try await call(OpenDirectConversation(
            memberID: member,
            operationID: ServiceOperationID(ClientOperationID.make())
        ))
    }

    func createConversation(_ draft: ConversationDraft) async throws -> ConversationCreationResult {
        try await call(CreateConversation(
            draft: draft,
            operationID: ServiceOperationID(ClientOperationID.make())
        ))
    }

    func mutateConversation(
        _ mutation: ConversationMutation, in conversation: Conversation.ID, operationID: String,
        expectedRevision: String?
    ) async throws -> ConversationMutationResult {
        try await call(MutateConversation(
            mutation: mutation,
            conversationID: conversation,
            operationID: ServiceOperationID(operationID),
            expectedRevision: expectedRevision
        ))
    }

    func conversationDetails(_ conversation: Conversation.ID) async throws -> ConversationDetails {
        try await call(GetConversationDetails(conversationID: conversation))
    }

    func participants(
        in conversation: Conversation.ID,
        after cursor: String?
    ) async throws -> ConversationParticipantPage {
        try await call(GetParticipants(conversationID: conversation, cursor: cursor))
    }

    func browseSpaces(
        _ query: SpaceDirectoryQuery,
        after cursor: String?
    ) async throws -> SpaceDirectoryPage {
        try await call(BrowseSpaces(query: query, cursor: cursor))
    }

    func conversationPreview(_ conversation: Conversation.ID) async throws -> ConversationPreview {
        try await call(GetConversationPreview(conversationID: conversation))
    }
}
