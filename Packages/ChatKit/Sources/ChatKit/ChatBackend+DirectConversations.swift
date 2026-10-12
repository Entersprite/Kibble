import Foundation

public extension ChatBackend {
    func openDirectConversation(with _: Member.ID) async throws -> Conversation {
        throw ChatError.unsupported(capability: "canOpenDirectConversations")
    }
}
