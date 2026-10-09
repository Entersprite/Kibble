import ChatKit
import Foundation

// MARK: - The three thread requests

public extension FakeBackend {
    /// One thread's messages, oldest first, its first message included, and
    /// whether you follow it, as `.threadChanged` with `.followed`: what the
    /// bridge gets from `list_messages` and `get_user_topic_metadata` (threads
    /// spec §3). A read, so it needs no connection, like `loadMessages`.
    func loadThread(_ thread: MessageThread.ID, in conversation: Conversation.ID) async throws -> [Message] {
        try require(capabilities.supportsThreads, "supportsThreads")
        let messages = try requireThread(thread, in: conversation)
        emitThreadChange(.followed(world.threadState(thread).isFollowed), thread: thread, in: conversation)
        return messages
    }

    /// Follows or unfollows a thread: kept in the world, reported as
    /// `.followed`, and the conversation's unread-thread flag moved when
    /// that changes it. An awaited write, so it needs a connection, like
    /// `setNotificationSetting`.
    func setThreadFollowed(
        _ followed: Bool,
        thread: MessageThread.ID,
        in conversation: Conversation.ID
    ) async throws {
        try require(capabilities.supportsThreads, "supportsThreads")
        try requireConnected()
        try requireThread(thread, in: conversation)
        world.threadStates[thread, default: FixtureThreadState()].isFollowed = followed
        emitThreadChange(.followed(followed), thread: thread, in: conversation)
        refreshUnreadThreads(in: conversation)
    }

    /// The Threads list: every followed thread's first message and its
    /// newest reply, newest activity first, each thread also reported as
    /// `.followed(true)` and `.counted` (threads spec §3). Which reply the
    /// real answer carries is `[Verify]`; the fixture's is the newest.
    func loadFollowedThreads() async throws -> [Message] {
        try require(capabilities.supportsThreads, "supportsThreads")
        var answer: [Message] = []
        for root in followedRoots() {
            let thread = root.threadID
            let conversation = root.conversationID
            answer.append(root)
            let replies = world.messages(in: thread, of: conversation).filter { $0.isReply && !$0.isDeleted }
            if let newest = replies.last {
                answer.append(newest)
            }
            emitThreadChange(.followed(true), thread: thread, in: conversation)
            emitThreadChange(counted(thread, in: conversation), thread: thread, in: conversation)
        }
        return answer
    }
}

// MARK: - What the server says about threads

extension FakeBackend {
    /// `.markThreadRead` and `.setThreadUnreadMark`, kept in the world and
    /// reported the way the bridge reports its server's answer: `.read` and
    /// `.markedUnread`, then the conversation's flag when it moves. Whether
    /// the real server's read also clears a mark is `[Verify]`; the
    /// fixture's does not, so a client's own clear is what clears it.
    func applyThreadMark(_ command: ChatCommand) throws {
        try require(capabilities.supportsThreads, "supportsThreads")
        switch command {
        case let .markThreadRead(conversation, thread, upTo):
            try requireThread(thread, in: conversation)
            world.threadStates[thread, default: FixtureThreadState()].readPosition = upTo
            emitThreadChange(.read(upTo: upTo), thread: thread, in: conversation)
            refreshUnreadThreads(in: conversation)
        case let .setThreadUnreadMark(conversation, thread, at):
            try requireThread(thread, in: conversation)
            world.threadStates[thread, default: FixtureThreadState()].markedUnreadAt = at
            emitThreadChange(.markedUnread(at: at), thread: thread, in: conversation)
            refreshUnreadThreads(in: conversation)
        default:
            break
        }
    }

    /// What the server pushes after a reply lands (`findings.md` §63.10):
    /// your own reply reads its thread up to itself and follows it (pushes 4
    /// and 9), every reply re-counts its thread (push 82), and the
    /// conversation's flag follows (push 53).
    func announceReply(_ reply: Message) {
        guard capabilities.supportsThreads else { return }
        let thread = reply.threadID
        let conversation = reply.conversationID
        if reply.sender == world.me {
            world.threadStates[thread, default: FixtureThreadState()].readPosition = reply.createdAt
            world.threadStates[thread, default: FixtureThreadState()].isFollowed = true
            emitThreadChange(.read(upTo: reply.createdAt), thread: thread, in: conversation)
            emitThreadChange(.followed(true), thread: thread, in: conversation)
        }
        emitThreadChange(counted(thread, in: conversation), thread: thread, in: conversation)
        refreshUnreadThreads(in: conversation)
    }

    /// What a history page reports per thread with a reply (threads spec
    /// §2.2): `.counted`, `.read` when there is a position, and
    /// `.markedUnread`, `nil` for no mark. Nothing for a thread without
    /// replies, and nothing at all from a backend without threads.
    func emitThreadState(of page: [Message], in conversation: Conversation.ID) {
        guard capabilities.supportsThreads else { return }
        for thread in FixtureWorld.threadsWithReplies(in: page) {
            let state = world.threadState(thread)
            emitThreadChange(counted(thread, in: conversation), thread: thread, in: conversation)
            if let readPosition = state.readPosition {
                emitThreadChange(.read(upTo: readPosition), thread: thread, in: conversation)
            }
            emitThreadChange(.markedUnread(at: state.markedUnreadAt), thread: thread, in: conversation)
        }
    }

    /// Push 53: when a change moves whether `conversation` has an unread
    /// thread, the world's flag follows and `.unreadThreadsChanged` says so.
    func refreshUnreadThreads(in conversation: Conversation.ID) {
        let hasUnread = world.hasUnreadThread(in: conversation)
        guard let index = world.conversations.firstIndex(where: { $0.id == conversation }),
              world.conversations[index].hasUnreadThread != hasUnread
        else { return }
        world.conversations[index].hasUnreadThread = hasUnread
        emit(.unreadThreadsChanged(conversationID: conversation, hasUnread: hasUnread))
    }

    /// `.counted` for a thread now: its messages (the first included,
    /// tombstones not) and its unread replies by the world's rule.
    func counted(_ thread: MessageThread.ID, in conversation: Conversation.ID) -> ThreadChange {
        let live = world.messages(in: thread, of: conversation).count { !$0.isDeleted }
        return .counted(messages: live, unread: world.unreadReplies(in: thread, of: conversation))
    }

    func emitThreadChange(
        _ change: ThreadChange,
        thread: MessageThread.ID,
        in conversation: Conversation.ID
    ) {
        emit(.threadChanged(threadID: thread, conversationID: conversation, change: change))
    }

    /// Throws unless the world holds a message in `thread`. A thread call or
    /// a reply naming any other is refused rather than invented.
    @discardableResult
    func requireThread(_ thread: MessageThread.ID, in conversation: Conversation.ID) throws -> [Message] {
        let messages = world.messages(in: thread, of: conversation)
        guard !messages.isEmpty else {
            throw ChatError.unknown("no thread \(thread) in \(conversation) in this fixture world")
        }
        return messages
    }

    /// The first message of every followed thread, newest activity first,
    /// ties by thread id. Read off the message list, never by iterating
    /// `threadStates`, whose order changes from launch to launch.
    func followedRoots() -> [Message] {
        var seen: Set<MessageThread.ID> = []
        let roots = world.messages.filter { message in
            !message.isReply && world.threadState(message.threadID).isFollowed
                && seen.insert(message.threadID).inserted
        }
        let activity = Dictionary(grouping: world.messages, by: \.threadID)
            .mapValues { $0.map(\.createdAt).max() ?? .distantPast }
        return roots.sorted { left, right in
            let leftAt = activity[left.threadID] ?? left.createdAt
            let rightAt = activity[right.threadID] ?? right.createdAt
            if leftAt != rightAt {
                return leftAt > rightAt
            }
            return left.threadID.rawValue < right.threadID.rawValue
        }
    }
}
