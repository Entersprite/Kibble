import ChatKit
import Foundation

public extension FakeBackend {
    func conversionConsequences(_ id: Conversation.ID) async throws -> ConversionConsequences {
        let details = try await conversationDetails(id)
        guard details.membership == .joined, details.conversation.kind == .groupDirectMessage,
              details.allowedActions.contains("convertToSpace") else {
            throw ChatError.unsupported(capability: "conversionConsequences")
        }
        let outcomes: [(ConversionTopic, ConversionOutcome)] = [
            (.sameConversation, .kept), (.membership, .kept), (.messages, .kept),
            (.history, .unknown), (.invitations, .unknown), (.integrations, .unknown),
            (.externalPeople, .unknown), (.undo, .notReversible)
        ]
        return ConversionConsequences(
            items: outcomes.map { ConversionConsequence(topic: $0.0, outcome: $0.1) },
            requiresHistoryAcknowledgement: true
        )
    }
}
