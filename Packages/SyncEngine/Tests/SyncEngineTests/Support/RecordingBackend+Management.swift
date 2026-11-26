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

    func holdMutations(_ hold: Bool) {
        holdingMutations = hold
    }

    func releaseHeldMutation() {
        guard !heldMutations.isEmpty else { return }
        heldMutations.removeFirst().resume()
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
        if holdingMutations {
            await withCheckedContinuation { heldMutations.append($0) }
        }
        var result = try await inner.mutateConversation(
            mutation, in: conversation, operationID: operationID, expectedRevision: expectedRevision
        )
        if leavingMutationsUnconfirmed {
            result.isConfirmed = false
        }
        return result
    }

    func participants(in conversation: Conversation.ID, after cursor: String?) async throws
        -> ConversationParticipantPage {
        try await inner.participants(in: conversation, after: cursor)
    }

    func conversationIntegrations(_ conversation: Conversation.ID) async throws -> ConversationIntegrations {
        try await inner.conversationIntegrations(conversation)
    }

    func searchConversationApps(_ query: String, in conversation: Conversation.ID) async throws
        -> [ConversationApp] {
        try await inner.searchConversationApps(query, in: conversation)
    }

    func openAppConversation(_ app: Member.ID, from conversation: Conversation.ID) async throws
        -> Conversation {
        try await inner.openAppConversation(app, from: conversation)
    }

    func webhookDeliveryURL(_ webhookID: String, in conversation: Conversation.ID) async throws -> URL {
        try await inner.webhookDeliveryURL(webhookID, in: conversation)
    }

    func conversationEmail(_ conversation: Conversation.ID) async throws -> ConversationEmail {
        try await inner.conversationEmail(conversation)
    }

    func conversionConsequences(_ conversation: Conversation.ID) async throws -> ConversionConsequences {
        try await inner.conversionConsequences(conversation)
    }
}
