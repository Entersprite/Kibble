import ChatKit
import Foundation
import GChatBridgeCore

extension LocalBridgeBackend {
    /// Replacement messages retain fields this build cannot name. A details
    /// form uses one update_group request for all of its changed fields.
    func updateManagementDetails(
        name: String? = nil, description: String?, guidelines: String?, emoji: String? = nil,
        context: ManagementWriteContext
    ) async throws {
        let space = context.before.conversation.kind == .space
        guard name != nil || description != nil || guidelines != nil || emoji != nil,
              name == nil || context.before.allowedActions.contains("rename"),
              description == nil || context.before.allowedActions.contains("description"),
              guidelines == nil || space && context.before.allowedActions.contains("guidelines"),
              emoji == nil || space && context.before.allowedActions.contains("emoji") else {
            throw ChatError.unsupported(capability: "detailsFields")
        }
        guard (description?.utf16.count ?? 0) <= 150, (guidelines?.utf16.count ?? 0) <= 5000,
              (name?.utf16.count ?? 0) <= 128, (emoji?.count ?? 0) <= 1,
              name == nil || !space ||
              !(name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
            throw ChatError.unknown("A conversation detail exceeds its character limit or is empty.")
        }
        let current = try await freshManagementGroup(context)
        var request = ConversationManagementRequests.identity(context.group, name: name, description: nil)
        if description != nil || guidelines != nil {
            var details = current.groupDetails
            if let description {
                details.description_p = description
            }
            if let guidelines {
                details.guidelines = guidelines
            }
            request.spaceDetails = details
            request.updateMasks.append(.spaceDetails)
        }
        if let emoji {
            var avatar = current.avatarInfo
            avatar.emoji = Emoji(); avatar.emoji.unicode = emoji
            request.avatarInfo = avatar
            request.updateMasks.append(.avatarInfo)
        }
        let response = try await context.client.call(.updateGroup, request)
        try checkManagementGeneration(context.generation)
        // Updates may acknowledge only the changed group. Confirm sparse replies
        // through a fresh read; never repeat a write to obtain an echo.
        let confirmed = try await managementUpdateSnapshot(
            response, context: context,
            needsRead: !response.hasGroup || !Self.managementUpdateMatches(
                request,
                group: response.group,
                requiresEchoFields: true
            )
        )
        guard confirmed.groupID == context.group,
              Self.managementUpdateMatches(request, group: confirmed) else {
            throw unconfirmedManagement()
        }
    }

    private static func managementUpdateMatches(
        _ request: UpdateGroupRequest, group: Group, requiresEchoFields: Bool = false
    ) -> Bool {
        if requiresEchoFields {
            guard !request.hasName || group.hasName,
                  !request.hasAvatarInfo || group.hasAvatarInfo,
                  !request.hasSpaceDetails || group.hasGroupDetails else { return false }
        }
        return (!request.hasName || group.name == request.name)
            && (!request.hasAvatarInfo || group.avatarInfo.emoji.unicode == request.avatarInfo.emoji.unicode)
            &&
            (!request.hasSpaceDetails || group.groupDetails.description_p == request.spaceDetails
                .description_p
                && group.groupDetails.guidelines == request.spaceDetails.guidelines)
    }

    func managementUpdateSnapshot(
        _ response: UpdateGroupResponse, context: ManagementWriteContext, needsRead: Bool
    ) async throws -> Group {
        if response.hasGroup, response.group.hasGroupID, response.group.groupID != context.group {
            throw unconfirmedManagement()
        }
        if !needsRead {
            return response.group
        }
        let read = try await context.client.call(
            .managementDetails, ConversationManagementRequests.details(context.group)
        )
        try checkManagementGeneration(context.generation)
        guard read.hasGroup, read.group.groupID == context.group else { throw unconfirmedManagement() }
        return read.group
    }
}
