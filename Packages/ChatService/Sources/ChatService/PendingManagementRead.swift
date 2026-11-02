import ChatKit

/// A management read depends on its conversation and returned profiles, not
/// unrelated transcript traffic or another query's catalog registration.
struct PendingManagementRead {
    let conversation: Conversation.ID
    let baseline: Conversation?
    var invalidated = false
    var changedMembers: Set<Member.ID> = []

    func accepts(members: [Member.ID]) -> Bool {
        !invalidated && changedMembers.isDisjoint(with: members)
    }

    mutating func observe(_ event: ChatEvent) {
        observeConversation(event)
        switch event {
        case let .membersResolved(members): changedMembers.formUnion(members.map(\.id))
        case let .selfIdentified(member): changedMembers.insert(member.id)
        case let .membersChanged(id, members):
            changedMembers.formUnion(members.map(\.id))
            invalidate(id)
        default: break
        }
        if changedMembers.count > 8192 {
            invalidated = true
            changedMembers = []
        }
    }

    private mutating func observeConversation(_ event: ChatEvent) {
        switch event {
        case let .conversationUpdated(row), let .conversationClassified(row): invalidate(row.id)
        case let .messageUpdated(message): invalidate(message.conversationID)
        case let .messageDeleted(_, id): invalidate(id)
        case let .conversationRemoved(id, _), let .gap(scope: .conversation(id), reason: _): invalidate(id)
        case let .conversationsChanged(rows):
            let row = rows.first { $0.id == conversation }
            if row == nil || row?.members != baseline?.members || row?.kind != baseline?.kind
                || row?.title != baseline?.title || row?.avatarURL != baseline?.avatarURL
                || row?.memberCount != baseline?.memberCount {
                invalidated = true
            }
        case .historyInvalidated, .gap(scope: .everything, reason: _): invalidated = true
        case let .conversationHistoryInvalidated(ids):
            if ids.contains(conversation) {
                invalidated = true
            }
        default: break
        }
    }

    private mutating func invalidate(_ id: Conversation.ID) {
        if conversation == id {
            invalidated = true
        }
    }
}
