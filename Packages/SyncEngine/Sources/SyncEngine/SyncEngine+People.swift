import ChatKit
import Foundation

/// The directory and membership requests, passed through (mention non-members
/// spec §3.4). Requests rather than commands, like `customEmojiImage`.
extension SyncEngine {
    func searchPeople(_ query: String) async throws -> [Member] {
        try await backend.searchPeople(query)
    }

    func membership(
        of member: Member.ID,
        in conversation: Conversation.ID
    ) async throws -> ConversationMembership {
        try await backend.membership(of: member, in: conversation)
    }
}
