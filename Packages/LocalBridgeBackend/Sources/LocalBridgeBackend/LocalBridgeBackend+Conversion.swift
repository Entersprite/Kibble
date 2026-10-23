import ChatKit
import Foundation
import GChatBridgeCore

extension LocalBridgeBackend {
    func convertManagementChat(
        name: String,
        emoji: String?,
        acknowledged: Bool,
        context: ManagementWriteContext
    ) async throws {
        guard context.before.conversation.kind == .groupDirectMessage, acknowledged,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf16.count <= 128, emoji == nil || (emoji?.count ?? 0) <= 1 else {
            throw ChatError.unsupported(capability: "convertToSpace")
        }
        _ = try await freshManagementGroup(context)
        try await conversationRPC(ConversationConversionRequests.convert(
            context.group,
            name: name,
            emoji: emoji
        ))
        try checkManagementGeneration(context.generation)
        let response = try await context.client.call(
            .managementDetails,
            ConversationManagementRequests.details(context.group)
        )
        try checkManagementGeneration(context.generation)
        guard response.hasGroup, response.group.groupID == context.group,
              [.flatRoom, .threadedRoom, .postRoom].contains(response.group.attributeCheckerGroupType),
              response.group.name == name,
              emoji == nil || response.group.avatarInfo.emoji.hasUnicode && response.group.avatarInfo.emoji
              .unicode == emoji else {
            throw unconfirmedManagement()
        }
    }
}
