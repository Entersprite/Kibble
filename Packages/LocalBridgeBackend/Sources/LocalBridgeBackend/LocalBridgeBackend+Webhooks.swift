import ChatKit
import Foundation
import GChatBridgeCore

public extension LocalBridgeBackend {
    func conversationIntegrations(_ id: Conversation.ID) async throws -> ConversationIntegrations {
        let generation = directoryGeneration
        let details = try await conversationDetails(id)
        guard details.membership == .joined, let group = ChannelEventMapping.groupID(for: id) else {
            throw ChatError.unsupported(capability: "conversationWebhooks")
        }
        let rows = try await managementWebhooks(group, generation: generation)
        let actions = details.allowedActions.intersection(["editWebhook", "deleteWebhook"])
        let apps = try await managementApps(group, generation: generation)
        let appActions = details.allowedActions
            .contains("removeApp") ? Set(["removeApp", "message"]) : ["message"]
        return try ConversationIntegrations(
            webhooks: rows.map { row in
                try ConversationWebhook(
                    id: row.id.serializedData().base64EncodedString(), name: row.name,
                    avatarURL: row.avatarURL.isEmpty ? nil : URL(string: row.avatarURL),
                    allowedActions: actions
                )
            }, canCreateWebhook: details.allowedActions.contains("createWebhook"),
            apps: apps.map { row in var value = row; value.allowedActions = appActions; return value },
            canAddApps: details.allowedActions.contains("addApp")
        )
    }

    func webhookDeliveryURL(_ webhookID: String, in id: Conversation.ID) async throws -> URL {
        let generation = directoryGeneration
        let details = try await conversationDetails(id)
        guard details.membership == .joined,
              !details.allowedActions.isDisjoint(with: ["createWebhook", "editWebhook", "deleteWebhook"]),
              let group = ChannelEventMapping.groupID(for: id) else {
            throw ChatError.unsupported(capability: "conversationWebhooks")
        }
        let reference = try webhookReference(webhookID, group: group)
        let rows = try await managementWebhooks(group, generation: generation)
        guard let value = rows.first(where: { $0.id == reference }),
              let url = URL(string: value.url), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw ChatError.decoding("The webhook delivery URL is unavailable.")
        }
        return url
    }
}

extension LocalBridgeBackend {
    func managementWebhooks(_ group: GroupId, generation: Int) async throws -> [IncomingWebhook] {
        let response = try await conversationRPCPayload(WebhookRequests.list(group))
        try checkManagementGeneration(generation)
        let decoded = PBLiteDecoder.decode(GetIncomingWebhooksResponse.self, from: response)
        guard decoded.issues.allSatisfy({ $0.kind == .unknownField }),
              decoded.message.webhooks.count <= 512 else {
            throw ChatError.decoding("The webhook list could not be read.")
        }
        let expected = try WebhookRequests.groupReference(group)
        let rows = decoded.message.webhooks
        guard rows.allSatisfy({ $0.hasID && $0.id.group == expected && !$0.id.id.isEmpty }),
              Set(rows.map(\.id.id)).count == rows.count else {
            throw ChatError.decoding("The webhook list does not match this conversation.")
        }
        return rows
    }

    func webhookReference(_ id: String, group: GroupId) throws -> WebhookReference {
        guard id.utf8.count <= 4096, let data = Data(base64Encoded: id),
              let reference = try? WebhookReference(serializedBytes: data),
              try reference.group == (WebhookRequests.groupReference(group)), !reference.id.isEmpty else {
            throw ChatError.unknown("This webhook belongs to a different conversation or is unavailable.")
        }
        return reference
    }

    func applyWebhookWrite(_ mutation: ConversationMutation, context: ManagementWriteContext) async throws {
        switch mutation {
        case let .saveWebhook(id, name, avatarURL):
            try await saveManagementWebhook(id: id, name: name, avatarURL: avatarURL, context: context)
        case let .deleteWebhook(id):
            let reference = try webhookReference(id, group: context.group)
            let rows = try await managementWebhooks(context.group, generation: context.generation)
            guard rows.contains(where: { $0.id == reference }) else { throw unconfirmedManagement() }
            try await conversationRPC(WebhookRequests.delete(reference))
            try checkManagementGeneration(context.generation)
            let remaining = try await managementWebhooks(context.group, generation: context.generation)
            guard !remaining.contains(where: { $0.id == reference }) else { throw unconfirmedManagement() }
        default: throw ChatError.unsupported(capability: "conversationWebhooks")
        }
    }

    private func saveManagementWebhook(
        id: String?, name: String, avatarURL: String, context: ManagementWriteContext
    ) async throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf16.count <= 25,
              name.range(of: "\\s{6,}", options: .regularExpression) == nil,
              avatarURL.utf16.count <= 1000,
              avatarURL.isEmpty || URL(string: avatarURL)?.scheme == "https" else {
            throw ChatError.unknown("Enter a webhook name of up to 25 characters and a valid avatar URL.")
        }
        let call: BatchExecuteCall
        if let id {
            let reference = try webhookReference(id, group: context.group)
            let rows = try await managementWebhooks(context.group, generation: context.generation)
            guard rows.contains(where: { $0.id == reference }) else { throw unconfirmedManagement() }
            call = try WebhookRequests.update(reference, name: name, avatarURL: avatarURL)
        } else {
            call = try WebhookRequests.create(context.group, name: name, avatarURL: avatarURL)
        }
        let response = try await conversationRPCPayload(call)
        try checkManagementGeneration(context.generation)
        let decoded = PBLiteDecoder.decode(IncomingWebhookResponse.self, from: response)
        guard decoded.issues.allSatisfy({ $0.kind == .unknownField }), decoded.message.hasWebhook,
              try decoded.message.webhook.id.group == (WebhookRequests.groupReference(context.group)),
              !decoded.message.webhook.id.id.isEmpty, decoded.message.webhook.name == name,
              decoded.message.webhook.hasAvatarURL, decoded.message.webhook.avatarURL == avatarURL else {
            throw unconfirmedManagement()
        }
        if let id, try webhookReference(id, group: context.group) != decoded.message.webhook.id {
            throw unconfirmedManagement()
        }
    }
}
