import ChatKit

struct MeetingMetadataUpdate: Sendable {
    let meeting: MeetingOccurrence?
}

extension SyncEngine {
    /// Detail metadata may arrive before a concurrent directory snapshot lands.
    /// Keep bounded session overlays so that snapshot cannot erase the update.
    func meetingMetadataWrites(for event: ChatEvent) -> [StoreWrite] {
        switch event {
        case let .meetingMetadataChanged(id, meeting):
            meetingMetadataUpdates[id] = MeetingMetadataUpdate(meeting: meeting)
            if meetingMetadataUpdates.count > 1024,
               let oldestKey = meetingMetadataUpdates.keys.min(by: { $0.rawValue < $1.rawValue }) {
                meetingMetadataUpdates[oldestKey] = nil
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
