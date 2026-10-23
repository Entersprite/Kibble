import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func dispatchIntegrations(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        switch request.operation {
        case GetConversationEmail.operation:
            guard capabilities.canManageConversationEmail else { throw ServiceFailure.unsupportedOperation }
            let payload = try request.decodePayload(GetConversationEmail.self)
            let value = try await withProviderWork(epoch: epoch) {
                try await backend.conversationEmail(payload.conversationID)
            }
            try checkEpoch(epoch)
            return try ServiceCodec.value(value)
        case GetConversionConsequences.operation:
            // No capability flag: eligibility is per conversation and the provider refuses.
            let payload = try request.decodePayload(GetConversionConsequences.self)
            let value = try await withProviderWork(epoch: epoch) {
                try await backend.conversionConsequences(payload.conversationID)
            }
            try checkEpoch(epoch)
            return try ServiceCodec.value(value)
        case SearchConversationApps.operation:
            guard capabilities.canManageConversationApps else { throw ServiceFailure.unsupportedOperation }
            let payload = try request.decodePayload(SearchConversationApps.self)
            let value = try await mediaQuery(epoch: epoch, urgency: WorkUrgency(interactive: true)) {
                try await backend.searchConversationApps(payload.query, in: payload.conversationID)
            } remember: { catalog, value, date in
                try catalog.rememberQueryMembers(value.map(\.member), at: date)
            }
            try checkEpoch(epoch)
            return try ServiceCodec.value(value)
        case GetConversationIntegrations.operation:
            return try await dispatchIntegrationListing(request, backend: backend, epoch: epoch)
        case GetWebhookDeliveryURL.operation:
            guard capabilities.canManageConversationWebhooks
            else { throw ServiceFailure.unsupportedOperation }
            let payload = try request.decodePayload(GetWebhookDeliveryURL.self)
            let value = try await withProviderWork(epoch: epoch) {
                try await backend.webhookDeliveryURL(payload.webhookID, in: payload.conversationID)
            }
            try checkEpoch(epoch)
            return try ServiceCodec.value(value)
        default: throw ServiceFailure.unsupportedOperation
        }
    }

    private func dispatchIntegrationListing(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        guard capabilities.canManageConversationWebhooks || capabilities.canManageConversationApps else {
            throw ServiceFailure.unsupportedOperation
        }
        let payload = try request.decodePayload(GetConversationIntegrations.self)
        let supportsApps = capabilities.canManageConversationApps
        let supportsWebhooks = capabilities.canManageConversationWebhooks
        let value = try await mediaQuery(epoch: epoch, urgency: WorkUrgency(interactive: true)) {
            var value = try await backend.conversationIntegrations(payload.conversationID)
            if !supportsApps {
                value.apps = []; value.canAddApps = false
            }
            if !supportsWebhooks {
                value.webhooks = []; value.canCreateWebhook = false
            }
            return value
        } remember: { catalog, value, date in
            let profiles = value.apps.map(\.member) + value.webhooks.map {
                Member(id: Member.ID($0.id), kind: .app, displayName: $0.name, avatarURL: $0.avatarURL)
            }
            try catalog.rememberQueryMembers(profiles, at: date)
        }
        try checkEpoch(epoch)
        return try ServiceCodec.value(value)
    }
}
