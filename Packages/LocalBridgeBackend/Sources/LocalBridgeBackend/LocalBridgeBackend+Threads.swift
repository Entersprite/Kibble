import ChatKit
import Foundation
import GChatBridgeCore

/// The thread calls (threads spec §3; `findings.md` §64, the writes measured
/// in §64.7). Each emits its outcome only once the server accepted it, and
/// only into the session that asked (`directoryGeneration`).
public extension LocalBridgeBackend {
    /// `list_messages`' page for a thread, here and in the reaction refetch: a
    /// thread is capped at 500 replies (§63.7, `[Verify]`), and the call has no
    /// cursor and answers the oldest end, so one page is the whole thread.
    static let threadPageSize: Int32 = 500

    /// A thread, its first message included, oldest first. Also asks
    /// `get_user_topic_metadata` once, because history does not say whether
    /// you follow a thread (§64.1); a failure there emits nothing (ruling 8).
    /// The page is returned even when the session changed meanwhile (ruling
    /// 5); only what it would emit, and the name lookup, are dropped.
    func loadThread(
        _ thread: MessageThread.ID, in conversation: Conversation.ID
    ) async throws -> [ChatKit.Message] {
        let target = try threadTarget(thread, conversation, what: "loadThread(_:in:)")
        let generation = directoryGeneration
        var request = ListMessagesRequest()
        request.requestHeader = APIRequestHeader.make()
        request.parentID.topicID = target.topic
        request.pageSize = Self.threadPageSize
        let response: ListMessagesResponse
        do {
            response = try await target.client.call(.listMessages, request)
        } catch {
            throw Self.chatError(fromAPI: error, call: "the /api/ list_messages call")
        }
        let messages = response.messages.compactMap(ChannelEventMapping.domainMessage)
            .sorted { $0.createdAt < $1.createdAt }
        if generation == directoryGeneration {
            resolveUnknownMembers(messages.map(\.sender))
        }
        await emitFollowState(of: target, generation: generation)
        return messages
    }

    /// Follow is `mute: false`, Unfollow `mute: true` (§64.1). Throws when the
    /// answer does not carry field 1, so the toggle does not flip.
    func setThreadFollowed(
        _ followed: Bool, thread: MessageThread.ID, in conversation: Conversation.ID
    ) async throws {
        let target = try threadTarget(thread, conversation, what: "setThreadFollowed(_:thread:in:)")
        let generation = directoryGeneration
        let response: MarkTopicMuteStateResponse
        do {
            response = try await target.client.call(
                .markTopicMuteState, ThreadCallRequests.muteState(topic: target.topic, mute: !followed)
            )
        } catch {
            throw Self.chatError(fromAPI: error, call: "the /api/ mark_Topic_mute_state call")
        }
        guard ThreadCallRequests.answer(response, carries: 1) else {
            throw ChatError.unknown(
                "mark_Topic_mute_state answered 200 without field 1, so nothing confirms the change"
            )
        }
        guard generation == directoryGeneration else { return }
        emit(target.event(.followed(followed)))
    }

    /// The Threads list (§64.6): each followed thread's first message and the
    /// one reply the answer carries. Emits `.followed(true)` per thread, and
    /// what its read state says, never its count (ruling 2) and never a
    /// cleared mark (`ThreadMapping.Listing.threadsList`).
    func loadFollowedThreads() async throws -> [ChatKit.Message] {
        guard let apiClient else {
            throw ChatError.unknown(
                "loadFollowedThreads() requires connect() to succeed first - "
                    + "there is no verified session or xsrf token yet"
            )
        }
        let generation = directoryGeneration
        let response: PaginatedWorldResponse
        do {
            response = try await apiClient.call(.paginatedWorld, ThreadCallRequests.followedThreads())
        } catch {
            throw Self.chatError(fromAPI: error, call: "the /api/ paginated_world call for followed threads")
        }
        var messages: [ChatKit.Message] = []
        var events: [ChatEvent] = []
        for entity in response.worldEntities where entity.hasTopic {
            let topic = entity.topic
            guard !topic.id.topicID.isEmpty,
                  let conversation = ChannelEventMapping.conversationID(topic.id.groupID)
            else { continue }
            messages += topic.replies.compactMap(ChannelEventMapping.domainMessage)
            events.append(.threadChanged(
                threadID: MessageThread.ID(topic.id.topicID), conversationID: conversation,
                change: .followed(true)
            ))
            events += ThreadMapping.events(for: topic, in: conversation, listing: .threadsList)
        }
        if generation == directoryGeneration {
            events.forEach(emit)
            resolveUnknownMembers(messages.map(\.sender))
        }
        return messages.sorted { $0.createdAt < $1.createdAt }
    }
}

extension LocalBridgeBackend {
    /// A thread's address and the client to reach it.
    struct ThreadTarget {
        let client: ProtoAPIClient
        let topic: TopicId
        let thread: MessageThread.ID
        let conversation: Conversation.ID

        func event(_ change: ThreadChange) -> ChatEvent {
            .threadChanged(threadID: thread, conversationID: conversation, change: change)
        }
    }

    /// `.markRead`, `.markThreadRead` and `.setThreadUnreadMark`: one `case`
    /// in `send(_:)`, for its case-label budget (ruling 6).
    func markReadState(_ command: ChatCommand) async throws {
        switch command {
        case let .markRead(conversationID, upTo):
            try await markRead(conversationID, upTo: upTo)
        case let .markThreadRead(conversationID, threadID, upTo):
            try await markThreadRead(threadID, in: conversationID, upTo: upTo)
        case let .setThreadUnreadMark(conversationID, threadID, at):
            try await setThreadUnreadMark(threadID, in: conversationID, at: at)
        default:
            throw ChatError.unsupported(capability: "markReadState")
        }
    }

    /// The client and topic, or a refusal before the network: an empty topic
    /// must never reach Google (`address`'s rule in `+EditDelete.swift`).
    func threadTarget(
        _ thread: MessageThread.ID, _ conversation: Conversation.ID, what: String
    ) throws -> ThreadTarget {
        guard let apiClient else {
            throw ChatError.unknown(
                "\(what) requires connect() to succeed first - "
                    + "there is no verified session or xsrf token yet"
            )
        }
        guard let group = ChannelEventMapping.groupID(for: conversation) else {
            throw ChatError.unknown(
                "\(what): \(conversation.rawValue) has neither the space/ nor the dm/ prefix "
                    + "this backend produces"
            )
        }
        guard !thread.rawValue.isEmpty else {
            throw ChatError.unknown("\(what) needs a thread, and this one has no id")
        }
        var topic = TopicId()
        topic.groupID = group
        topic.topicID = thread.rawValue
        return ThreadTarget(client: apiClient, topic: topic, thread: thread, conversation: conversation)
    }

    private func emitFollowState(of target: ThreadTarget, generation: Int) async {
        guard let response = try? await target.client.call(
            .getUserTopicMetadata, ThreadCallRequests.metadata(topic: target.topic)
        ), response.hasIsMuted, generation == directoryGeneration else { return }
        emit(target.event(.followed(!response.isMuted)))
    }

    /// One microsecond past `date`, the conversation's rule (§36, §42). The
    /// position sent is the one emitted (ruling 7).
    private func markThreadRead(
        _ thread: MessageThread.ID, in conversation: Conversation.ID, upTo date: Date
    ) async throws {
        let target = try threadTarget(thread, conversation, what: "markThreadRead")
        let micros = Microseconds.adding(Self.readPositionOffsetMicroseconds, to: Microseconds.from(date))
        let generation = directoryGeneration
        let response: MarkTopicReadStateResponse
        do {
            response = try await target.client.call(
                .markTopicReadState, ThreadCallRequests.markRead(topic: target.topic, micros: micros)
            )
        } catch {
            throw Self.chatError(fromAPI: error, call: "the /api/ mark_topic_readstate call")
        }
        guard response.hasUserRevision else {
            throw ChatError.unknown(
                "mark_topic_readstate answered 200 without a revision (field 2), so nothing confirms the mark"
            )
        }
        guard generation == directoryGeneration else { return }
        emit(target.event(.read(upTo: Microseconds.date(micros))))
    }

    /// "Mark as unread" sends the message's time minus 1 µs (§64.3); `nil`
    /// sends 0, which clears. The mark emitted is the one sent (ruling 7).
    private func setThreadUnreadMark(
        _ thread: MessageThread.ID, in conversation: Conversation.ID, at date: Date?
    ) async throws {
        let target = try threadTarget(thread, conversation, what: "setThreadUnreadMark")
        let micros = date.map { Microseconds.adding(-1, to: Microseconds.from($0)) } ?? 0
        let request = ThreadCallRequests.unreadTimestamp(topic: target.topic, micros: micros)
        let generation = directoryGeneration
        let response: SetTopicUnreadTimestampResponse
        do {
            response = try await target.client.call(.setTopicUnreadTimestamp, request)
        } catch {
            throw Self.chatError(fromAPI: error, call: "the /api/ set_topic_unread_timestamp call")
        }
        guard ThreadCallRequests.answer(response, carries: 1) else {
            throw ChatError.unknown(
                "set_topic_unread_timestamp answered 200 without field 1, so nothing confirms the mark"
            )
        }
        guard generation == directoryGeneration else { return }
        emit(target.event(.markedUnread(at: date == nil ? nil : Microseconds.date(micros))))
    }
}
