import ChatKit
import Foundation

/// The server's side of one thread in a fixture world: whether you follow
/// it, how far you have read it, and a mark as unread (threads spec §1) -
/// what a real server keeps as the topic's mute flag and `TopicReadState`.
public struct FixtureThreadState: Sendable, Hashable {
    public var isFollowed: Bool
    public var readPosition: Date?
    public var markedUnreadAt: Date?

    public init(isFollowed: Bool = false, readPosition: Date? = nil, markedUnreadAt: Date? = nil) {
        self.isFollowed = isFollowed
        self.readPosition = readPosition
        self.markedUnreadAt = markedUnreadAt
    }
}

// MARK: - Threads

public extension FixtureWorld {
    /// One thread's messages, oldest first, its first message included.
    func messages(in thread: MessageThread.ID, of conversation: Conversation.ID) -> [Message] {
        messages.filter { $0.conversationID == conversation && $0.threadID == thread }
    }

    /// A thread's server state. A thread with none is unfollowed, never read
    /// and unmarked.
    func threadState(_ thread: MessageThread.ID) -> FixtureThreadState {
        threadStates[thread] ?? FixtureThreadState()
    }

    /// The threads in `messages` that have a reply, in the order their first
    /// reply appears: ordered by the array, never by a dictionary, so events
    /// built from it come out the same on every launch.
    static func threadsWithReplies(in messages: [Message]) -> [MessageThread.ID] {
        var seen: Set<MessageThread.ID> = []
        return messages.compactMap { message in
            message.isReply && seen.insert(message.threadID).inserted ? message.threadID : nil
        }
    }

    /// Replies from other people newer than the thread's read position,
    /// counted only for a followed thread that has one. The fixture's rule;
    /// what the server's own count does is `[Verify]` (`findings.md` §64.7,
    /// field 4). Equality is read (`findings.md` §42.2).
    func unreadReplies(in thread: MessageThread.ID, of conversation: Conversation.ID) -> Int {
        let state = threadState(thread)
        guard state.isFollowed, let readPosition = state.readPosition else { return 0 }
        return messages(in: thread, of: conversation).count { message in
            message.isReply && !message.isDeleted && message.sender != me
                && message.createdAt > readPosition
        }
    }

    /// Marked unread, or followed with an unread reply.
    func isUnread(_ thread: MessageThread.ID, of conversation: Conversation.ID) -> Bool {
        threadState(thread).markedUnreadAt != nil || unreadReplies(in: thread, of: conversation) > 0
    }

    /// Whether any thread in `conversation` is unread: what the server says
    /// in read state field 25 and push 53.
    func hasUnreadThread(in conversation: Conversation.ID) -> Bool {
        Self.threadsWithReplies(in: messages(in: conversation)).contains { isUnread($0, of: conversation) }
    }

    /// Thread state naming a thread with no message, and replies whose
    /// thread has no first message: both break the shape the wire has.
    func threadInconsistencies() -> [String] {
        let threads = Set(messages.map(\.threadID))
        let started = Set(messages.filter { !$0.isReply }.map(\.threadID))
        var problems: [String] = []
        let stated = threadStates.keys.sorted { $0.rawValue < $1.rawValue }
        for thread in stated where !threads.contains(thread) {
            problems.append("thread state \(thread) names a thread with no message")
        }
        for reply in messages where reply.isReply && !started.contains(reply.threadID) {
            problems.append("reply \(reply.id) is in \(reply.threadID), which has no first message")
        }
        return problems
    }
}
