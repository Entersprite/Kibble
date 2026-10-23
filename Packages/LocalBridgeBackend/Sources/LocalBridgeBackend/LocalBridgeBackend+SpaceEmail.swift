import ChatKit
import Foundation
import GChatBridgeCore

public extension LocalBridgeBackend {
    func conversationEmail(_ id: Conversation.ID) async throws -> ConversationEmail {
        let generation = directoryGeneration
        let details = try await conversationDetails(id)
        guard details.membership == .joined, details.conversation.kind == .space,
              let group = ChannelEventMapping.groupID(for: id), let me = calendarPoll.me else {
            throw ChatError.unsupported(capability: "conversationEmail")
        }
        let response = try await managementEmail(group, generation: generation)
        let value = response.details.first
        let owner = details.allowedActions.contains("deleteEmail")
            ? try await managementViewerIsOwner(
                group: group,
                me: me,
                rows: [],
                generation: generation,
                resolveWhenAbsent: true
            ) : false
        return ConversationEmail(
            address: value?.email,
            deliveryEnabled: value
                .flatMap { $0.hasEmailDeliverySetting && [1, 2].contains($0.emailDeliverySetting)
                    ? $0.emailDeliverySetting == 2 : nil
                },
            canGenerate: value == nil && response.canGenerate && details.allowedActions
                .contains("generateEmail"),
            canChangeDelivery: value != nil && details.allowedActions.contains("setEmailDelivery"),
            canDelete: value != nil && owner
        )
    }
}

extension LocalBridgeBackend {
    func managementEmail(_ group: GroupId, generation: Int) async throws -> ListSpaceEmailResponse {
        guard let client = apiClient else { throw ChatError.notAuthenticated }
        let response = try await client.call(.listSpaceEmail, SpaceEmailRequests.read(group))
        try checkManagementGeneration(generation)
        guard response.hasGroup, response.group == group, response.details.count <= 1,
              response.details.allSatisfy({ !$0.email.isEmpty && $0.email.utf16.count <= 320 }) else {
            throw ChatError.decoding("The space email settings are unavailable.")
        }
        return response
    }

    func applyEmailWrite(_ mutation: ConversationMutation, context: ManagementWriteContext) async throws {
        guard context.before.conversation.kind == .space else {
            throw ChatError.unsupported(capability: "conversationEmail")
        }
        let current = try await managementEmail(context.group, generation: context.generation)
        switch mutation {
        case .generateEmail:
            try await generateManagementEmail(current: current, context: context)
        case let .setEmailDelivery(enabled):
            try await changeManagementEmailDelivery(enabled: enabled, current: current, context: context)
        case .deleteEmail:
            try await deleteManagementEmail(current: current, context: context)
        default: throw ChatError.unsupported(capability: "conversationEmail")
        }
    }

    private func generateManagementEmail(
        current: ListSpaceEmailResponse,
        context: ManagementWriteContext
    ) async throws {
        guard current.details.isEmpty, current.canGenerate else {
            throw ChatError.unsupported(capability: "generateEmail")
        }
        let response = try await context.client.call(
            .generateSpaceEmail,
            SpaceEmailRequests.read(context.group)
        )
        try checkManagementGeneration(context.generation)
        guard response.group == context.group, response.details.count == 1,
              !response.details[0].email.isEmpty else { throw unconfirmedManagement() }
    }

    private func changeManagementEmailDelivery(
        enabled: Bool,
        current: ListSpaceEmailResponse,
        context: ManagementWriteContext
    ) async throws {
        guard let email = current.details.first, email.hasEmailDeliverySetting,
              [1, 2].contains(email.emailDeliverySetting) else { throw unconfirmedManagement() }
        let request = SpaceEmailRequests.delivery(enabled, for: email, in: context.group)
        let response = try await context.client.call(.updateSpaceEmail, request)
        try checkManagementGeneration(context.generation)
        guard response.hasDetails, response.details.email == email.email,
              response.details.hasEmailDeliverySetting,
              response.details.emailDeliverySetting == request.details.emailDeliverySetting else {
            throw unconfirmedManagement()
        }
    }

    private func deleteManagementEmail(
        current: ListSpaceEmailResponse,
        context: ManagementWriteContext
    ) async throws {
        guard let email = current.details.first,
              try await managementViewerIsOwner(
                  group: context.group, me: context.me, rows: [], generation: context.generation,
                  resolveWhenAbsent: true
              ) else { throw ChatError.unsupported(capability: "deleteEmail") }
        _ = try await context.client.call(
            .deleteSpaceEmail,
            SpaceEmailRequests.delete(email.email, in: context.group)
        )
        try checkManagementGeneration(context.generation)
        let after = try await managementEmail(context.group, generation: context.generation)
        guard after.details.isEmpty else { throw unconfirmedManagement() }
    }
}
