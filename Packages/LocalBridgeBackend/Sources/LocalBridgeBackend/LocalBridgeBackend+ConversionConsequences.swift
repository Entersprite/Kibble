import ChatKit
import Foundation

public extension LocalBridgeBackend {
    func conversionConsequences(_ id: Conversation.ID) async throws -> ConversionConsequences {
        let generation = directoryGeneration
        let details = try await conversationDetails(id)
        try checkManagementGeneration(generation)
        guard details.membership == .joined, details.conversation.kind == .groupDirectMessage,
              details.allowedActions.contains("convertToSpace") else {
            throw ChatError.unsupported(capability: "conversionConsequences")
        }
        // Only same-conversation identity is confirmed from source; the rest stays unknown.
        let unknown: [ConversionTopic] = [
            .membership, .messages, .history, .invitations, .integrations, .externalPeople, .undo
        ]
        return ConversionConsequences(
            items: [ConversionConsequence(topic: .sameConversation, outcome: .kept)]
                + unknown.map { ConversionConsequence(topic: $0, outcome: .unknown) },
            requiresHistoryAcknowledgement: true
        )
    }
}
