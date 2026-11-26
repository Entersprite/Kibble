import ChatKit
import Foundation

extension ReconciliationBackend {
    func searchConversationApps(_ query: String, in id: Conversation.ID) -> [ConversationApp] {
        appSearchReads += 1
        return integrations.apps
    }

    func openAppConversation(_ app: Member.ID, from id: Conversation.ID) -> Conversation {
        appOpens += 1
        return Conversation(id: .init("app-dm"), kind: .appDirectMessage, members: [app])
    }

    func conversationEmail(_ id: Conversation.ID) -> ConversationEmail {
        emailReads += 1
        return ConversationEmail(address: "room@example.invalid", deliveryEnabled: true)
    }

    func conversionConsequences(_ id: Conversation.ID) -> ConversionConsequences {
        consequenceReads += 1
        return consequences
    }

    func mutateConversation(
        _ mutation: ConversationMutation, in id: Conversation.ID,
        operationID: String, expectedRevision: String?
    ) -> ConversationMutationResult {
        managementMutations.append(mutation)
        return ConversationMutationResult(operationID: operationID)
    }
}
