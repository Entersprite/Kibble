import ChatKit
import Foundation
import SyncEngine

extension AudioCallRecipient {
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

extension AppEnvironment {
    func startCalls(service: (any AudioCallService)?, model: ChatSessionModel) {
        calls.start(service: service, directory: {
            AudioCallRecipient.directory(
                conversations: model.conversations, members: model.directory, me: model.me
            )
        })
    }
}
