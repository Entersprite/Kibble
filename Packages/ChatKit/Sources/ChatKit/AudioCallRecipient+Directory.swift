import Foundation

public extension AudioCallRecipient {
    /// Only a known human peer in a one-to-one conversation is eligible.
    /// This directory supplies candidates; providers still verify admission.
    static func directory(
        conversations: [Conversation], members: [Member.ID: Member], me: Member.ID?
    ) -> [AudioCallRecipient] {
        guard let me else { return [] }
        return conversations.compactMap { conversation in
            let ids = Set(conversation.members)
            guard conversation.kind == .directMessage, ids.count == 2, ids.contains(me),
                  let other = ids.first(where: { $0 != me }),
                  let member = members[other], member.kind == .human else { return nil }
            return AudioCallRecipient(
                conversationID: conversation.id, memberID: other,
                displayName: member.displayName ?? member.email ?? "Person"
            )
        }.sorted { $0.conversationID.rawValue < $1.conversationID.rawValue }
    }
}
