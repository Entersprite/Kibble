import ChatKit
import SwiftUI

/// A view identity no other account shares. A conversation or thread id is
/// unique only within its account, and two accounts in one organization see
/// the same spaces, so a view keyed by one alone would carry a half-typed
/// draft or a pending edit from one account into the other.
struct AccountScoped<Value: Hashable>: Hashable {
    let account: String?
    let value: Value
}

/// Where a transcript was when it left the screen: the message at its top,
/// or `nil` while it showed the newest, and the scroll request it had
/// already honoured.
struct TranscriptPosition {
    let message: Message.ID?
    let honoured: TranscriptScroll.Request?
}

/// What `MessageList` resumes from, and how it reports where it was.
struct TranscriptResume {
    let saved: TranscriptPosition?
    let leave: (TranscriptPosition) -> Void
}

/// Each account's transcript position, for as long as the window lives, so
/// switching accounts and back returns to the same place. One per account:
/// opening another conversation replaces it, so a conversation itself still
/// opens at its newest message.
@MainActor
final class TranscriptPositions {
    private var positions: [String: (conversation: Conversation.ID, position: TranscriptPosition)] = [:]

    func resume(account: String?, conversation: Conversation.ID?) -> TranscriptResume? {
        guard let conversation else { return nil }
        let key = account ?? ""
        let saved = positions[key].flatMap { $0.conversation == conversation ? $0.position : nil }
        return TranscriptResume(saved: saved) { [weak self] position in
            self?.positions[key] = (conversation, position)
        }
    }
}

/// The messages a transcript has on screen. A class, so recording them on
/// every scroll does not draw the transcript again.
final class TranscriptSeen {
    var ids: [Message.ID] = []

    /// The earliest message on screen.
    func top(in messages: [Message]) -> Message.ID? {
        let visible = Set(ids)
        return messages.first { visible.contains($0.id) }?.id
    }
}
