import ChatKit
import Foundation
import GChatBridgeCore

extension LocalBridgeBackend {
    func recoverUser(through end: Int64, generation: Int) async throws {
        guard let apiClient, delivery.cursor.user > 0, delivery.cursor.user < end else { return }
        for _ in 0 ..< 8 {
            let before = delivery.cursor.user
            let response = try await apiClient.call(
                .catchUpUser,
                CatchUpRequests.user(from: before, through: end)
            )
            try requireRecoverySession(generation)
            guard try permitsCatchUp(response) else {
                delivery.rebasedRecovery = true
                try await submitProviderBatch(.init(invalidatesHistory: true, patch: .init(user: end)))
                return
            }
            let next = response.events.map(\.userRevision.timestamp).max() ?? before
            try requireProgress(response, before: before, next: next)
            for event in response.events
                .sorted(by: { $0.userRevision.timestamp < $1.userRevision.timestamp }) {
                try await commitRecoveryEvent(
                    event,
                    patch: .init(user: event.userRevision.timestamp),
                    generation: generation
                )
            }
            if response.status == .completed {
                try await submitProviderBatch(.init(patch: .init(user: end)))
                return
            }
        }
        throw ChatError.decoding("Provider recovery exceeded its page budget.")
    }

    func recoverGroup(_ item: WorldItemLite, id: Conversation.ID, generation: Int) async throws {
        guard let apiClient else { throw CancellationError() }
        let end = item.groupRevision.timestamp
        for _ in 0 ..< 8 {
            let before = delivery.cursor.groups[id.rawValue] ?? 0
            let response = try await apiClient.call(
                .catchUpGroup, CatchUpRequests.group(item.groupID, from: before, through: end)
            )
            try requireRecoverySession(generation)
            guard try permitsCatchUp(response) else {
                // Only this conversation's missed changes are unknown.
                delivery.rebasedRecovery = true
                try await submitProviderBatch(.init(
                    events: [.conversationHistoryInvalidated([id])],
                    patch: .init(groups: [id.rawValue: end])
                ))
                return
            }
            let next = response.events.map(\.groupRevision.timestamp).max() ?? before
            try requireProgress(response, before: before, next: next)
            for event in response.events
                .sorted(by: { $0.groupRevision.timestamp < $1.groupRevision.timestamp }) {
                try await commitRecoveryEvent(
                    event,
                    patch: .init(groups: [id.rawValue: event.groupRevision.timestamp]),
                    generation: generation
                )
            }
            if response.status == .completed {
                try await submitProviderBatch(.init(patch: .init(groups: [id.rawValue: end])))
                return
            }
        }
        throw ChatError.decoding("Provider recovery exceeded its page budget.")
    }

    private func permitsCatchUp(_ response: CatchUpResponse) throws -> Bool {
        guard response.hasStatus
        else { throw ChatError.decoding("Provider recovery returned no coverage status.") }
        if response.status == .completed || response.status == .paginated {
            return true
        }
        guard [3, 4, 5].contains(response.status.rawValue) else {
            throw ChatError.decoding("Provider recovery returned an unfamiliar coverage status.")
        }
        return false
    }

    private func requireProgress(_ response: CatchUpResponse, before: Int64, next: Int64) throws {
        guard response.status != .paginated || next > before else {
            throw ChatError.decoding("Provider recovery did not advance.")
        }
    }

    private func commitRecoveryEvent(
        _ raw: Event, patch: ProviderCursorPatch, generation: Int
    ) async throws {
        let channel = try ChannelEvent(protobuf: raw)
        var events = try ChannelEventMapping.recoveryEvents(raw)
        for (body, event) in zip(channel.bodies, events) {
            reconcileHiddenConversation(
                event,
                type: body.typeTag
            )
        }
        events += try await recoverReactions(in: channel, generation: generation)
        events = events.map(completingOwnForward).filter(prepareEvent)
        messageTimes.remember(events.flatMap(Self.messages(in:)))
        resolveUnknownMembers(events.flatMap(Self.memberIDs(in:)))
        if events.isEmpty {
            try await submitProviderBatch(.init(patch: patch)); return
        }
        for (index, event) in events.enumerated() {
            let live: Bool = if case let .messageReceived(message) = event {
                message.createdAt >= delivery.notificationFloor
            } else {
                false
            }
            try await submitProviderBatch(.init(
                events: [event], patch: index == events.count - 1 ? patch : .init(), live: live
            ))
        }
    }

    private func recoverReactions(in event: ChannelEvent, generation: Int) async throws -> [ChatEvent] {
        guard let apiClient else { throw CancellationError() }
        var events: [ChatEvent] = []
        for body in event.bodies {
            guard let target = ChannelEventMapping.reactedMessage(in: body) else { continue }
            var request = ListMessagesRequest()
            request.requestHeader = APIRequestHeader.make()
            request.parentID = target.parent
            request.pageSize = Self.threadPageSize
            let response = try await apiClient.call(.listMessages, request)
            try requireRecoverySession(generation)
            guard let wire = response.messages.first(where: { $0.id.messageID == target.messageID.rawValue }),
                  let message = ChannelEventMapping.domainMessage(wire) else {
                // The bounded thread page cannot establish this reaction set.
                // Drop cached history confidence before accepting its revision:
                // the reacted conversation's alone when the target names it.
                events.append(
                    ChannelEventMapping.conversationID(target.parent.topicID.groupID)
                        .map { .conversationHistoryInvalidated([$0]) } ?? .historyInvalidated
                )
                continue
            }
            events.append(.reactionChanged(messageID: target.messageID, reactions: message.reactions))
        }
        return events
    }
}
