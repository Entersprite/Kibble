import ChatKit
import Foundation
import GChatBridgeCore

extension LocalBridgeBackend {
    /// The provider's world names DM members. Read it afresh before an invitation;
    /// cached directory data and client recipient hints confer no authority.
    /// This query must not restart directory polling or publish a world snapshot.
    func directMembership(
        of member: ChatKit.Member.ID, in conversation: Conversation.ID, using apiClient: ProtoAPIClient
    ) async throws -> ConversationMembership {
        let generation = directoryGeneration
        let response: PaginatedWorldResponse
        do {
            response = try await apiClient.call(.paginatedWorld, WorldRequestLadder.minimumViable.request)
        } catch {
            throw Self.chatError(fromAPI: error, call: "the /api/ paginated_world membership check")
        }
        try Task.checkCancellation()
        guard generation == directoryGeneration, isConnected else { throw CancellationError() }
        guard let current = WorldMapping.map(response).conversations.first(where: { $0.id == conversation }),
              current.kind == .directMessage, Set(current.members).count == 2 else { return .unknown }
        return current.members.contains(member) ? .member : .notMember
    }
}
