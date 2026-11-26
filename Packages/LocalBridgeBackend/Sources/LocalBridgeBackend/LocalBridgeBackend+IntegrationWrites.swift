import ChatKit
import Foundation
import GChatBridgeCore

extension LocalBridgeBackend {
    func applyManagementIntegrations(
        _ mutation: ConversationMutation,
        context: ManagementWriteContext
    ) async throws -> Bool {
        switch mutation {
        case .generateEmail, .setEmailDelivery, .deleteEmail:
            try await applyEmailWrite(mutation, context: context)
        case .addApp, .removeApp:
            try await applyAppWrite(mutation, context: context)
        case .saveWebhook, .deleteWebhook:
            try await applyWebhookWrite(mutation, context: context)
        default: return false
        }
        return true
    }
}

struct ManagementOperation {
    var id: Conversation.ID
    var mutation: ConversationMutation
    var result: ConversationMutationResult
}

struct ManagementWriteContext {
    var group: GroupId
    var before: ConversationDetails
    var me: ChatKit.Member.ID
    var client: ProtoAPIClient
    var generation: Int
}
