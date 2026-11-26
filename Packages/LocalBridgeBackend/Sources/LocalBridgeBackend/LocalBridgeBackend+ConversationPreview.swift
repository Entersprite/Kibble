import ChatKit
import Foundation
import GChatBridgeCore

/// A space's recent messages before joining it.
///
/// `list_topics` answers for a space the account has not joined: on the live
/// account it returned whole pages, with bodies and senders, for spaces the
/// directory listed as not joined, which `get_group` called invited, while
/// `get_group` carried no snippet for any of them. Whether it answers for
/// every unjoined kind is `[Verify]`; a refusal reaches the preview as an
/// error, and the details' snippet stays.
///
/// **Read for the preview and nothing else.** The page is mapped and
/// returned, never emitted: no thread, read state, head or member event
/// reaches the store, so the space does not become a joined conversation and
/// its senders are not polled for presence.
public extension LocalBridgeBackend {
    /// The most top-level messages a preview carries, newest kept.
    static let conversationPreviewLimit = 50

    func conversationPreview(_ id: Conversation.ID) async throws -> ConversationPreview {
        guard isConnected, let apiClient, let group = ChannelEventMapping.groupID(for: id) else {
            throw ChatError.notAuthenticated
        }
        guard case .spaceID = group.id else {
            throw ChatError.unsupported(capability: "canPreviewConversations")
        }
        let generation = directoryGeneration
        let response: ListTopicsResponse
        do {
            response = try await apiClient.call(.listTopics, TopicsRequestLadder.history(for: group).request)
        } catch {
            throw Self.chatError(fromAPI: error, call: "the /api/ list_topics call")
        }
        try checkManagementGeneration(generation)
        let messages = HistoryMapping.map(response).messages
            .filter { !$0.isReply && $0.conversationID == id }
            .sorted { $0.createdAt < $1.createdAt }
            .suffix(Self.conversationPreviewLimit)
        let senders = Set(messages.map(\.sender)).sorted { $0.rawValue < $1.rawValue }
        // Names are a courtesy: a preview whose senders could not be named
        // still shows what they said.
        let members = await senders.isEmpty ? [] : (try? apiClient.call(
            .getMembers, Self.getMembersRequest(senders)
        )).map { MemberMapping.map($0).members } ?? []
        try checkManagementGeneration(generation)
        return ConversationPreview(messages: Array(messages), members: members)
    }
}
