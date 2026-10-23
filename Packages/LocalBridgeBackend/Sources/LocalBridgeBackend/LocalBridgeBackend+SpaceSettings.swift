import ChatKit
import Foundation
import GChatBridgeCore

extension LocalBridgeBackend {
    func updateSpaceSettings(
        _ patch: ConversationSettingsPatch, context: ManagementWriteContext
    ) async throws {
        guard context.before.conversation.kind == .space,
              let settings = context.before.settings,
              patch.access == nil || settings.canChangeAccess,
              patch.requestToJoin == nil || settings.canChangeRequestToJoin,
              patch.permissions.allSatisfy({ id, _ in
                  settings.permissions.contains { $0.id == id && $0.isEditable }
              }), patch.access != nil || patch.requestToJoin != nil || !patch.permissions.isEmpty else {
            throw ChatError.unsupported(capability: "conversationSettings")
        }
        try SpaceSettingsMapping.validateMembershipVisibility(
            patch.permissions,
            current: settings.permissions
        )
        let snapshot = try await freshManagementResponse(context)
        let current = snapshot.group
        let organization = SpaceSettingsMapping.organizationAudience(snapshot.defaultTargetAudiences)
        var request = ConversationManagementRequests.identity(context.group, name: nil, description: nil)
        request.spacePermissions = try managementPermissionPatch(
            patch,
            current: current,
            organization: organization,
            settings: settings,
            before: context.before
        )
        request.updateMasks.append(.spacePermissions)
        let response = try await context.client.call(.updateGroup, request)
        try checkManagementGeneration(context.generation)
        guard response.hasGroup, response.group.groupID == context.group,
              !request.hasSpacePermissions || response.group.hasSpacePermissions
              && response.group.spacePermissions == request.spacePermissions else {
            throw unconfirmedManagement()
        }
    }

    private func managementPermissionPatch(
        _ patch: ConversationSettingsPatch,
        current: Group,
        organization: SpacePermissionAudience?,
        settings: ConversationSettings,
        before: ConversationDetails
    ) throws -> SpacePermissionSet {
        var permissions = try SpaceSettingsMapping.changing(
            current.spacePermissions, to: patch.permissions, organizationAudience: organization
        )
        if let access = patch.access {
            guard let organization else { throw ChatError.unsupported(capability: "conversationAccess") }
            permissions = try SpaceSettingsMapping.changingAccess(
                permissions,
                to: access,
                organization: organization
            )
        }
        guard (patch.access ?? before.access) != .open ||
            !(patch.requestToJoin ?? settings.requestToJoin ?? false) else {
            throw ChatError.unsupported(capability: "requestToJoin")
        }
        if let enabled = patch.requestToJoin {
            guard !enabled || (patch.access ?? before.access) != .open,
                  let index = permissions.rules.firstIndex(where: { $0.permission == 22 }),
                  permissions.rules.filter({ $0.permission == 22 }).count == 1 else {
                throw ChatError.unsupported(capability: "requestToJoin")
            }
            guard let audience = organization
            else { throw ChatError.unsupported(capability: "requestToJoin") }
            permissions.rules[index].roles.owners = false
            permissions.rules[index].roles.managers = false
            permissions.rules[index].roles.members = false
            permissions.rules[index].roles.organization = false
            permissions.rules[index].audiences.audiences = enabled ? [audience] : []
        }
        return permissions
    }

    func updateConversationEmoji(_ value: String, context: ManagementWriteContext) async throws {
        try await updateManagementDetails(description: nil, guidelines: nil, emoji: value, context: context)
    }

    func freshManagementGroup(_ context: ManagementWriteContext) async throws -> Group {
        try await freshManagementResponse(context).group
    }

    func freshManagementResponse(_ context: ManagementWriteContext) async throws -> GetGroupResponse {
        let response = try await context.client.call(
            .managementDetails, ConversationManagementRequests.details(context.group)
        )
        try checkManagementGeneration(context.generation)
        guard response.hasGroup, response.group.groupID == context.group else {
            throw unconfirmedManagement()
        }
        guard context.before.revision == nil || response.group.hasRevisionTime
            && String(response.group.revisionTime) == context.before.revision else {
            throw ChatError.unknown("This conversation changed. Reload before saving.")
        }
        return response
    }
}
