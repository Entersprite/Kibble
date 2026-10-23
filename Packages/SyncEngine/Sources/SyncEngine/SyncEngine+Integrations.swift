import ChatKit
import ChatPersistence
import Foundation

/// The Conversation Info sheet's reads. Each is returned, never stored, except
/// that opening an app's conversation records the conversation it opened. A
/// pure read survives an unrelated conversation change (`mutations: false`);
/// it still ends with the account.
public extension SyncEngine {
    func loadConversationIntegrations(_ id: Conversation.ID) async throws -> ConversationIntegrations {
        let version = managementScope
        let integrations = try await backend.conversationIntegrations(id)
        try checkManagementScope(version, mutations: false)
        return integrations
    }

    func searchConversationApps(_ query: String, in id: Conversation.ID) async throws -> [ConversationApp] {
        let version = managementScope
        let apps = try await backend.searchConversationApps(query, in: id)
        try checkManagementScope(version, mutations: false)
        return apps
    }

    /// Opens or restores the one-to-one conversation with an app installed in `id`.
    func openAppConversation(_ app: Member.ID, from id: Conversation.ID) async throws -> Conversation.ID {
        let version = managementScope
        let conversation = try await backend.openAppConversation(app, from: id)
        try checkManagementScope(version)
        guard conversation.kind == .appDirectMessage else {
            throw ChatError.decoding("The service opened a different kind of conversation.")
        }
        invalidateConversationSnapshot(conversation.id)
        try store.apply([.restoreConversation(conversation)])
        return conversation.id
    }

    /// A credential: the caller hands it to the person and keeps no copy.
    func webhookDeliveryURL(_ webhookID: String, in id: Conversation.ID) async throws -> URL {
        let version = managementScope
        let url = try await backend.webhookDeliveryURL(webhookID, in: id)
        try checkManagementScope(version, mutations: false)
        return url
    }

    func loadConversationEmail(_ id: Conversation.ID) async throws -> ConversationEmail {
        let version = managementScope
        let email = try await backend.conversationEmail(id)
        try checkManagementScope(version, mutations: false)
        return email
    }

    func loadConversionConsequences(_ id: Conversation.ID) async throws -> ConversionConsequences {
        let version = managementScope
        let consequences = try await backend.conversionConsequences(id)
        try checkManagementScope(version, mutations: false)
        return consequences
    }
}
