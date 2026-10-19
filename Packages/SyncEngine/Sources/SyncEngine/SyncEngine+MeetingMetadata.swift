import ChatKit
import ChatPersistence

struct MeetingMetadataUpdate: Sendable {
    let meeting: MeetingOccurrence?
    /// Arrival order, so a full overlay drops its oldest update.
    var sequence = 0
}

extension SyncEngine {
    /// Detail metadata may arrive before a concurrent directory snapshot lands.
    /// Keep bounded session overlays so that snapshot cannot erase the update.
    func meetingMetadataWrites(for event: ChatEvent) -> [StoreWrite] {
        switch event {
        case let .meetingMetadataChanged(id, meeting):
            meetingMetadataSequence += 1
            meetingMetadataUpdates[id] = MeetingMetadataUpdate(
                meeting: meeting,
                sequence: meetingMetadataSequence
            )
            if meetingMetadataUpdates.count > 1024,
               let oldest = meetingMetadataUpdates.min(by: { $0.value.sequence < $1.value.sequence })?.key {
                meetingMetadataUpdates[oldest] = nil
            }
            return []
        case let .conversationsChanged(conversations):
            return meetingMetadataWrites(for: conversations, replacing: true)
        case let .conversationUpdated(conversation):
            return meetingMetadataWrites(for: [conversation], replacing: false)
        case let .conversationRemoved(id, _):
            meetingMetadataUpdates[id] = nil
            return []
        default: return []
        }
    }

    func applyConversationSnapshot(_ conversations: [Conversation]) throws {
        try store.apply([.replaceConversations(conversations)] +
            meetingMetadataWrites(for: conversations, replacing: true))
    }

    private func meetingMetadataWrites(for conversations: [Conversation], replacing: Bool) -> [StoreWrite] {
        let eligible = Set(conversations.filter { $0.kind == .meetChat }.map(\.id))
        if replacing {
            meetingMetadataUpdates = meetingMetadataUpdates.filter { eligible.contains($0.key) }
        }
        return conversations.compactMap { conversation in
            if conversation.meeting != nil {
                meetingMetadataUpdates[conversation.id] = nil
                return nil
            }
            guard eligible.contains(conversation.id),
                  let update = meetingMetadataUpdates[conversation.id] else { return nil }
            return .setMeetingMetadata(conversation: conversation.id, meeting: update.meeting)
        }
    }
}
