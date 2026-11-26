import ChatKit
import Foundation

public extension FakeBackend {
    func conversationIntegrations(_ id: Conversation.ID) async throws -> ConversationIntegrations {
        try require(
            capabilities.canManageConversationWebhooks || capabilities.canManageConversationApps,
            "conversationIntegrations"
        )
        let details = try await conversationDetails(id)
        guard details.membership == .joined
        else { throw ChatError.unsupported(capability: "conversationWebhooks") }
        let actions = details.allowedActions.intersection(["editWebhook", "deleteWebhook"])
        return ConversationIntegrations(
            webhooks: (capabilities.canManageConversationWebhooks ? managedWebhooks[id] ?? [] : [])
                .map { row in
                    var value = row; value.allowedActions = actions; return value
                },
            canCreateWebhook: capabilities.canManageConversationWebhooks && details.allowedActions
                .contains("createWebhook"),
            apps: (capabilities.canManageConversationApps ? managedApps[id] ?? [] : []).map { row in
                var value = row
                value.allowedActions = details.allowedActions.contains("removeApp") ? [
                    "message",
                    "removeApp"
                ] : ["message"]
                return value
            }, canAddApps: capabilities.canManageConversationApps && details.allowedActions.contains("addApp")
        )
    }

    func webhookDeliveryURL(_ webhookID: String, in id: Conversation.ID) async throws -> URL {
        try require(capabilities.canManageConversationWebhooks, "conversationWebhooks")
        let listing = try await conversationIntegrations(id)
        guard listing.canCreateWebhook || listing.webhooks.contains(where: { !$0.allowedActions.isEmpty }),
              listing.webhooks.contains(where: { $0.id == webhookID }) else {
            throw ChatError.unknown("This webhook is unavailable.")
        }
        return URL(string: "https://example.invalid/webhooks/\(webhookID)")!
    }
}

extension FakeBackend {
    func changeManagedWebhooks(_ mutation: ConversationMutation, in conversation: Conversation.ID) throws {
        try require(capabilities.canManageConversationWebhooks, "conversationWebhooks")
        var rows = managedWebhooks[conversation] ?? []
        switch mutation {
        case let .saveWebhook(id, name, avatarURL):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf16.count <= 25,
                  name.range(of: "\\s{6,}", options: .regularExpression) == nil,
                  avatarURL.utf16.count <= 1000,
                  avatarURL.isEmpty || URL(string: avatarURL)?.scheme == "https" else {
                throw ChatError.unknown("Enter a webhook name of up to 25 characters and a valid avatar URL.")
            }
            if let id {
                guard let index = rows.firstIndex(where: { $0.id == id }) else {
                    throw ChatError.unknown("This webhook is unavailable.")
                }
                rows[index].name = name
                rows[index].avatarURL = avatarURL.isEmpty ? nil : URL(string: avatarURL)
            } else {
                rows.append(ConversationWebhook(
                    id: nextIdentifier("fixture-webhook"), name: name,
                    avatarURL: avatarURL.isEmpty ? nil : URL(string: avatarURL),
                    allowedActions: ["editWebhook", "deleteWebhook"]
                ))
            }
        case let .deleteWebhook(id):
            guard rows.contains(where: { $0.id == id })
            else { throw ChatError.unknown("This webhook is unavailable.") }
            rows.removeAll { $0.id == id }
        default: throw ChatError.unsupported(capability: "conversationWebhooks")
        }
        managedWebhooks[conversation] = rows
    }
}
