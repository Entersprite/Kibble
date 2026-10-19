import Foundation

/// Optional provider facility for combining several clients' receive-only
/// interests. It exposes no provider identifiers or subscription protocol.
public protocol ManagedChatActivityBackend: ChatBackend {
    func setReceiveInterests(
        presenceMembers: Set<Member.ID>, conversations: Set<Conversation.ID>
    ) async throws
}
