import ChatKit
import Foundation
import SwiftUI

public enum MeetingTranscriptPresentation {
    /// A divider marks the first loaded message of each occurrence. It never
    /// exposes a disclosure, a reply destination or a synthetic message ID.
    public static func dividers(
        messages: [Message], occurrences: [Conversation]
    ) -> [Message.ID: Date] {
        let starts = Dictionary(uniqueKeysWithValues: occurrences.compactMap { conversation in
            conversation.meeting.map { (conversation.id, $0.scheduledStart) }
        })
        var previous: Conversation.ID?
        var result: [Message.ID: Date] = [:]
        for message in messages {
            if previous != message.conversationID {
                result[message.id] = starts[message.conversationID]
            }
            previous = message.conversationID
        }
        return result
    }
}

struct MeetingOccurrenceDivider: View {
    let start: Date

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.separator).frame(height: 1)
            Text(start.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .layoutPriority(1)
            Rectangle().fill(.separator).frame(height: 1)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}
