import ChatKit
import Foundation
import GChatBridgeCore

extension LocalBridgeBackend {
    func deliver(_ array: ChannelArray) {
        guard let event = ChannelEvent(array) else { return }
        recordInTally(event)
        if delivery.running {
            receiveCheckpointedEvent(event)
        } else {
            for event in prepareChannelEvent(event) {
                continuation.yield(event)
            }
        }
    }

    func prepareChannelEvent(_ event: ChannelEvent) -> [ChatEvent] {
        for body in event.bodies {
            if let reacted = ChannelEventMapping.reactedMessage(in: body) {
                requestReactionRefetch(reacted)
            }
        }
        let mapped = ChannelEventMapping.chatEvents(from: event)
        messageTimes.remember(mapped.flatMap(Self.messages(in:)))
        var accepted: [ChatEvent] = []
        for (body, event) in zip(event.bodies, mapped) {
            reconcileHiddenConversation(event, type: body.typeTag)
            if prepareEvent(event) {
                accepted.append(event)
            }
        }
        resolveUnknownMembers(mapped.flatMap(Self.memberIDs(in:)))
        return accepted
    }

    func receiveCheckpointedEvent(_ event: ChannelEvent) {
        if isBlockedByRecovery(event) {
            bufferProviderEvent(event)
            return
        }
        let mapped = prepareChannelEvent(event)
        let proposed = cursorPatch(for: event, events: mapped)
        let patch = deferReactionRevisions(event, proposed: proposed)
        enqueueProviderBatch(.init(
            events: mapped,
            patch: delivery.recoveryIncomplete ? .init() : patch,
            live: true
        ))
    }

    func isBlockedByRecovery(_ event: ChannelEvent) -> Bool {
        guard delivery.recovering else { return false }
        if delivery.blocksAll {
            return true
        }
        if event.revision?.scope == .user {
            return delivery.blocksUser
        }
        let ids = Set(ChannelEventMapping.chatEvents(from: event).compactMap(Self.recoveryConversation)
            .map(\.rawValue))
        return ids.isEmpty || !ids.isDisjoint(with: delivery.blockedGroups)
    }

    private func bufferProviderEvent(_ event: ChannelEvent) {
        let size = event.bodies.reduce(0) { $0 + ((try? $1.value.jsonData().count) ?? 8 * 1024 * 1024) }
        guard delivery.buffered.count < 1024, delivery.bufferedBytes + size <= 8 * 1024 * 1024 else {
            delivery.overflowed = true
            delivery.recoveryRequested = true
            return
        }
        delivery.buffered.append(event)
        delivery.bufferedBytes += size
    }

    func cursorPatch(for event: ChannelEvent, events: [ChatEvent]) -> ProviderCursorPatch {
        guard let revision = event.revision, revision.timestamp > 0 else { return .init() }
        if revision.scope == .user {
            return .init(user: revision.timestamp)
        }
        var ids = Set(events.compactMap(Self.recoveryConversation))
        for body in event.bodies {
            if let reaction = ChannelEventMapping.reactedMessage(in: body),
               let id = ChannelEventMapping.conversationID(reaction.parent.topicID.groupID) {
                ids.insert(id)
            }
        }
        guard ids.count == 1, let id = ids.first else { return .init() }
        return .init(groups: [id.rawValue: revision.timestamp])
    }

    static func recoveryConversation(_ event: ChatEvent) -> Conversation.ID? {
        switch event {
        case let .messageReceived(message), let .messageUpdated(message): message.conversationID
        case let .messageDeleted(_, id), let .conversationRemoved(id, _), let .readStateChanged(id, _, _),
             let .conversationUnreadMarkChanged(id, _), let .unreadThreadsChanged(id, _): id
        case let .conversationUpdated(row): row.id
        case let .threadChanged(_, id, _): id
        default: nil
        }
    }
}
