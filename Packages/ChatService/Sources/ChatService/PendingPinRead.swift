import ChatKit

/// Only changes that can affect this collection or its returned profiles retire a read.
struct PendingPinRead {
    let conversation: Conversation.ID
    let baseline: Conversation?
    var invalidated = false
    var changedMembers: Set<Member.ID> = []
    var changedMessages: Set<Message.ID> = []

    func accepts(_ value: PinnedMessages) -> Bool {
        !invalidated && changedMembers.isDisjoint(with: value.members.map(\.id)) &&
            changedMessages.isDisjoint(with: value.messages.map(\.id))
    }

    mutating func observe(_ event: ChatEvent) {
        observeMembers(event)
        observeMessages(event)
        observeDirectory(event)
        if changedMembers.count > 8192 || changedMessages.count > 512 {
            invalidated = true
            changedMembers = []
            changedMessages = []
        }
    }

    private mutating func observeMembers(_ event: ChatEvent) {
        switch event {
        case let .membersResolved(members): changedMembers.formUnion(members.map(\.id))
        case let .selfIdentified(member): changedMembers.insert(member.id)
        case let .membersChanged(id, members):
            changedMembers.formUnion(members.map(\.id))
            invalidate(id)
        default: break
        }
    }

    private mutating func observeMessages(_ event: ChatEvent) {
        switch event {
        case let .reactionChanged(id, _): changedMessages.insert(id)
        case let .messageUpdated(message): invalidate(message.conversationID)
        case let .messageReceived(message):
            if message.activity == .pinnedMessage {
                invalidate(message.conversationID)
            }
        case let .messageDeleted(_, id), let .messagePinsChanged(id): invalidate(id)
        default: break
        }
    }

    private mutating func observeDirectory(_ event: ChatEvent) {
        switch event {
        case let .conversationRemoved(id, _), let .gap(scope: .conversation(id), reason: _): invalidate(id)
        case let .conversationUpdated(row), let .conversationClassified(row): invalidate(row.id)
        case let .conversationsChanged(rows): observeDirectory(rows)
        case let .conversationHistoryInvalidated(ids):
            if ids.contains(conversation) {
                invalidated = true
            }
        case .historyInvalidated, .gap(scope: .everything, reason: _): invalidated = true
        default: break
        }
    }

    private mutating func observeDirectory(_ rows: [Conversation]) {
        let row = rows.first { $0.id == conversation }
        if row == nil || row?.members != baseline?.members || row?.kind != baseline?.kind {
            invalidated = true
        }
    }

    private mutating func invalidate(_ id: Conversation.ID) {
        if id == conversation {
            invalidated = true
        }
    }
}
