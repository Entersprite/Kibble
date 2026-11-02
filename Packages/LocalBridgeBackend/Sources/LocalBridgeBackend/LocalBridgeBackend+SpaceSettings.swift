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
        let snapshot = try await managementStep("settingsSnapshot") {
            try await freshManagementResponse(context)
        }
        let current = snapshot.group
        let organization = SpaceSettingsMapping.organizationAudience(snapshot.defaultTargetAudiences)
        let updated = try await managementStep("settingsPatch") {
            try managementPermissionPatch(
                patch, current: current, organization: organization,
                settings: settings, before: context.before
            )
        }
        let permissions = SpaceSettingsMapping.patch(
            updated, over: current.spacePermissions, includeAccess: patch.access != nil
        )
        guard !permissions.rules.isEmpty
        else { throw ChatError.unsupported(capability: "unchangedSettings") }
        let request = ConversationManagementRequests.spaceSettings(context.group, permissions: permissions)
        let response = try await managementStep("settingsRequest") {
            try await sendSettingsRequest(request, snapshot: snapshot, context: context)
        }
        try checkManagementGeneration(context.generation)
        try await managementStep("settingsConfirmation") {
            let confirmed = try await managementUpdateSnapshot(
                response, context: context,
                needsRead: !response.hasGroup || !response.group.hasSpacePermissions
                    || !SpaceSettingsMapping.confirms(
                        request.spacePermissions,
                        in: response.group.spacePermissions
                    )
            )
            guard confirmed.groupID == context.group, confirmed.hasSpacePermissions,
                  SpaceSettingsMapping.confirms(request.spacePermissions, in: confirmed.spacePermissions)
            else {
                throw unconfirmedManagement()
            }
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
            guard !enabled || (patch.access ?? before.access) != .open else {
                throw ChatError.unsupported(capability: "requestToJoin")
            }
            permissions = try SpaceSettingsMapping.changingJoinRequests(permissions, to: enabled)
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
