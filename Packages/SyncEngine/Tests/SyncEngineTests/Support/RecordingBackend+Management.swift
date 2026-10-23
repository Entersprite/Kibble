import ChatKit
import Foundation

/// A conversation's settings, details and mutations, forwarded to the fixture;
/// mutations are recorded, for adding people before a send. Its own file for
/// `RecordingBackend.swift`'s length.
extension RecordingBackend {
    func setNotificationSetting(
        _ level: NotificationLevel,
        for conversation: Conversation.ID
    ) async throws {
        try await inner.setNotificationSetting(level, for: conversation)
    }

    /// Answers every later mutation as written but unconfirmed, as a write
    /// whose answer was lost is.
    func leaveMutationsUnconfirmed(_ unconfirmed: Bool) {
        leavingMutationsUnconfirmed = unconfirmed
    }

    func conversationDetails(_ conversation: Conversation.ID) async throws -> ConversationDetails {
        try await inner.conversationDetails(conversation)
    }

    func mutateConversation(
        _ mutation: ConversationMutation,
        in conversation: Conversation.ID,
        operationID: String,
        expectedRevision: String?
    ) async throws -> ConversationMutationResult {
        mutations.append(mutation)
        var result = try await inner.mutateConversation(
            mutation, in: conversation, operationID: operationID, expectedRevision: expectedRevision
        )
        if leavingMutationsUnconfirmed {
            result.isConfirmed = false
        }
        return result
    }
}
