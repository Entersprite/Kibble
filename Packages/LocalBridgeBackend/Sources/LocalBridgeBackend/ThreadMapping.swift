import ChatKit
import Foundation
import GChatBridgeCore

/// Threads, off the wire (threads spec §2.2): which message is a reply, and
/// what a topic's read state says about its thread. The one place these are
/// decided, for history, pushes and `list_messages` alike.
enum ThreadMapping {
    /// `[Verify]` until the owner's §64.9 run: whether `TopicReadState` field 4
    /// is the thread's unread count. A conversation's own field 4 is always
    /// zero (`findings.md` §37.8), so it is not trusted until measured. While
    /// `false`, history's `.counted` says nothing about unread, and the
    /// store's fallback rule decides (Task 5).
    static let unreadCountIsField4 = false

    /// Field 34 when present (217 of 217 replies, §63.3); without it, a reply
    /// is a message whose id is not its topic's, because a topic is named after
    /// its first message (648 of 648, §63.3).
    static func isReply(_ message: GChatBridgeCore.Message) -> Bool {
        if message.hasIsInlineReply {
            return message.isInlineReply
        }
        let topic = message.id.parentID.topicID.topicID
        return !topic.isEmpty && message.id.messageID != topic
    }

    /// Which answer a topic came from. Two separate questions hang on it:
    /// whether the messages listed are the whole thread, and whether the read
    /// state is a snapshot.
    enum Listing: Equatable {
        /// A history page. Its read state is a snapshot for every thread, so
        /// an absent field 14 clears a mark set elsewhere (ruling 3).
        /// `countIsComplete` is `false` for a listing that reached the reply
        /// cap: it may be a longer thread cut short, and `.counted` would
        /// replace the stored count with a smaller one.
        case history(countIsComplete: Bool)

        /// The Threads list: one reply per topic, so it counts nothing it
        /// lists (ruling 2). Its answer carries no read state and loads after
        /// every world load, so it sets a mark only when field 14 says so and
        /// never clears one.
        case threadsList

        var countsWhatItLists: Bool {
            if case let .history(countIsComplete) = self {
                countIsComplete
            } else {
                false
            }
        }

        var readStateIsSnapshot: Bool {
            if case .history = self {
                true
            } else {
                false
            }
        }
    }

    /// A thread's count, read position and mark-as-unread time, for a topic
    /// with at least one reply. Nothing for a single-message topic (652 of
    /// 713 in §64.7). Field 10 is the count whenever present; `listing`
    /// decides the rest, and has no default, so every caller says which it is.
    static func events(for topic: Topic, in conversation: Conversation.ID, listing: Listing) -> [ChatEvent] {
        guard !topic.id.topicID.isEmpty, topic.replies.contains(where: isReply) else { return [] }
        let state = topic.topicReadState
        var changes: [ThreadChange] = []
        if let messages = messageCount(topic, countsWhatItLists: listing.countsWhatItLists) {
            let unread = unreadCountIsField4 && state.hasUnreadMessageCount
                ? Int(state.unreadMessageCount) : nil
            changes.append(.counted(messages: messages, unread: unread))
        }
        if state.hasLastReadTime, state.lastReadTime > 0 {
            changes.append(.read(upTo: Microseconds.date(state.lastReadTime)))
        }
        let marked = state.hasMarkTopicAsUnreadTime && state.markTopicAsUnreadTime > 0
            ? Microseconds.date(state.markTopicAsUnreadTime) : nil
        if listing.readStateIsSnapshot || marked != nil {
            changes.append(.markedUnread(at: marked))
        }
        let thread = MessageThread.ID(topic.id.topicID)
        return changes.map { .threadChanged(threadID: thread, conversationID: conversation, change: $0) }
    }

    /// Field 10 when present; otherwise the messages listed, the first
    /// included, as `MessageThread.replyCount` counts them.
    private static func messageCount(_ topic: Topic, countsWhatItLists: Bool) -> Int? {
        let state = topic.topicReadState
        if state.hasTotalMessageCount, state.totalMessageCount > 0 {
            return Int(state.totalMessageCount)
        }
        return countsWhatItLists ? topic.replies.count : nil
    }
}
