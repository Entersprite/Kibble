import ChatKit
import Foundation
import GChatBridgeCore

extension LocalBridgeBackend {
    func performConversationAction(_ action: ConversationAction, in id: Conversation.ID) async throws {
        do {
            try await applyConversationAction(action, in: id)
        } catch let error as APIFailure {
            throw Self.chatError(fromAPI: error, call: "the conversation action")
        }
    }

    private func applyConversationAction(_ action: ConversationAction, in id: Conversation.ID) async throws {
        guard capabilities.supports(action), let apiClient else {
            throw ChatError.unsupported(capability: action.wire)
        }
        // Refresh before using membership or a timestamp. A sidebar snapshot
        // can predate the newest message or a membership change on another device.
        let conversations = try await loadConversations()
        try Task.checkCancellation()
        guard let conversation = conversations.first(where: { $0.id == id }),
              action.isAvailable(for: conversation.kind), let item = conversationDetails[id] else {
            throw ChatError.unsupported(capability: action.wire)
        }
        switch action {
        case .markUnread:
            try await markConversationUnread(id, item: item)
        case .hide:
            let response = try await apiClient.call(
                .hideGroup,
                ConversationActionRequests.hide(group: item.groupID)
            )
            guard response.hasReadState || response.hasUserRevision else { throw unconfirmed(action) }
            try Task.checkCancellation()
            hiddenConversations.insert(id)
            hiddenThrough[id] = max(
                item.sortTimestamp,
                item.readState.lastHeadMessageCreateTimeUsec,
                response.readState.hideTimestamp
            )
            emit(.conversationRemoved(conversationID: id, historyBefore: nil))
        case .block:
            try await blockConversation(conversation, group: item.groupID, using: apiClient)
        case .leave:
            try await leaveConversation(id, group: item.groupID, using: apiClient)
        case .delete:
            let cutoff = max(item.sortTimestamp, item.readState.lastHeadMessageCreateTimeUsec)
            guard cutoff > 0 else { throw unconfirmed(action) }
            let before = Microseconds.date(cutoff)
            try await conversationRPC(ConversationActionRequests.clearHistory(
                group: item.groupID,
                micros: Microseconds.from(before)
            ))
            historyCutoffs[id] = max(historyCutoffs[id] ?? 0, cutoff)
            hiddenConversations.insert(id)
            hiddenThrough[id] = cutoff
            emit(.conversationRemoved(conversationID: id, historyBefore: before))
        case .unknown: throw ChatError.unsupported(capability: action.wire)
        }
    }

    private func markConversationUnread(_ id: Conversation.ID, item: WorldItemLite) async throws {
        let head = item.readState.lastHeadMessageCreateTimeUsec
        let sort = item.hasSortTimestamp ? item.sortTimestamp : head
        let newest = head > 0 && sort > 0 ? min(head, sort) : max(head, sort)
        guard newest > 1 else { throw unconfirmed(.markUnread) }
        let at = newest - 1
        try await setConversationUnreadTimestamp(group: item.groupID, micros: at)
        conversationDetails[id]?.readState.markAsUnreadTimestampUsec = at
        emit(.conversationUnreadMarkChanged(conversationID: id, at: Microseconds.date(at)))
    }

    private func blockConversation(
        _ conversation: Conversation,
        group: GroupId,
        using client: ProtoAPIClient
    ) async throws {
        var user: UserId?
        if conversation.kind == .directMessage || conversation.kind == .appDirectMessage {
            guard let me = calendarPoll.me else { throw unconfirmed(.block) }
            let others = conversation.members.filter { $0 != me }
            guard others.count == 1 else { throw unconfirmed(.block) }
            var target = UserId()
            target.id = others[0].rawValue
            user = target
        }
        let response = try await client.call(
            .blockEntity,
            ConversationActionRequests.block(group: group, user: user)
        )
        guard response.hasUserRevision || response.hasReadState else { throw unconfirmed(.block) }
        try Task.checkCancellation()
        // Blocking one person affects every one-to-one conversation with them.
        let affected = conversationDetails.compactMap { id, item -> Conversation.ID? in
            guard let user else { return id == conversation.id ? id : nil }
            let kind = WorldMapping.kind(for: item)
            guard kind == .directMessage || kind == .appDirectMessage else { return nil }
            return item.dmMembers.members.contains(where: { $0.id == user.id }) ? id : nil
        }
        for id in Set(affected + [conversation.id]) {
            hiddenConversations.remove(id)
            emit(.conversationRemoved(conversationID: id, historyBefore: nil))
        }
    }

    private func leaveConversation(
        _ id: Conversation.ID,
        group: GroupId,
        using client: ProtoAPIClient
    ) async throws {
        guard let me = calendarPoll.me else { throw unconfirmed(.leave) }
        var user = UserId()
        user.id = me.rawValue
        var member = MemberId()
        member.userID = user
        let response = try await client.call(
            .removeMemberships,
            ConversationActionRequests.leave(group: group, member: member)
        )
        guard let result = response.results.first(where: { $0.memberID == member }),
              ProtoFieldScan.varintValues(ofField: 2, in: result.unknownFields.data).allSatisfy({ $0 == 0 })
        else {
            throw unconfirmed(.leave)
        }
        try Task.checkCancellation()
        emit(.conversationRemoved(conversationID: id, historyBefore: nil))
    }

    func clearConversationUnreadMark(_ id: Conversation.ID) async throws {
        guard let item = conversationDetails[id], item.readState.markAsUnreadTimestampUsec > 0 else { return }
        try await setConversationUnreadTimestamp(group: item.groupID, micros: 0)
        conversationDetails[id]?.readState.markAsUnreadTimestampUsec = 0
        emit(.conversationUnreadMarkChanged(conversationID: id, at: nil))
    }

    private func unconfirmed(_ action: ConversationAction) -> ChatError {
        .unknown("The service did not confirm \(action.wire).")
    }
}
