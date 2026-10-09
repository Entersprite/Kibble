import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The thread calls (threads spec §3), reached through a real `connect()`.
/// Answers carry what §64.7 measured: the mute and unread answers field 1,
/// mark read fields 1 and 2, metadata `{1, 2 is_muted}`. Tests assert the
/// events, not only the requests (`CLAUDE.md`: a test transport's default
/// answer is a claim about the wire).
@Suite(.timeLimit(.minutes(1)))
struct ThreadCallsTests {
    private static let cookies = SessionCookies(header: "SID=a; COMPASS=b; OSID=c")!
    private let conversation = Conversation.ID("space/s-1")
    private let thread = MessageThread.ID("t-1")

    private func topic() -> TopicId {
        var space = SpaceId()
        space.spaceID = "s-1"
        var topic = TopicId()
        topic.groupID.spaceID = space
        topic.topicID = "t-1"
        return topic
    }

    /// A body carrying field 1 (and 2), by field number: the generated
    /// answers name nothing there (Task 2, ruling 3).
    private func accepted(withRevision: Bool = false) -> Data {
        var writer = ProbeProtoWriter()
        writer.message(1) { $0.int64(1, 7) }
        if withRevision {
            writer.message(2) { $0.int64(1, 8) }
        }
        return writer.data
    }

    private func metadata(muted: Bool?) -> Data {
        var writer = ProbeProtoWriter()
        writer.message(1) { $0.int64(1, 7) }
        if let muted {
            writer.bool(2, muted)
        }
        return writer.data
    }

    private func listMessages(_ ids: [String]) throws -> Data {
        var response = ListMessagesResponse()
        response.messages = ids.enumerated().map { index, id in
            var message = GChatBridgeCore.Message()
            message.id.messageID = id
            message.id.parentID.topicID = topic()
            message.creator.userID.id = "u-1"
            message.createTime = 1_700_000_000_000_000 + Int64(index)
            if index > 0 {
                message.isInlineReply = true
            }
            return message
        }.reversed()
        return try response.serializedBytes()
    }

    private func connected(
        _ answers: [String: Data], holding held: Set<String> = []
    ) async throws -> (LocalBridgeBackend, ThreadCallTransport) {
        let transport = ThreadCallTransport(answers: answers, holding: held)
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()
        return (backend, transport)
    }

    // MARK: - loadThread

    @Test func aThreadLoadsOldestFirstWithItsRepliesMarked() async throws {
        let (backend, transport) = try await connected([
            "list_messages": listMessages(["t-1", "r-1", "r-2"]),
            "get_user_topic_metadata": metadata(muted: false)
        ])
        let page = try await backend.loadThread(thread, in: conversation)
        #expect(page.map(\.id.rawValue) == ["t-1", "r-1", "r-2"])
        #expect(page.map(\.isReply) == [false, true, true])

        var expected = ListMessagesRequest()
        expected.parentID.topicID = topic()
        expected.pageSize = 500
        let sent = try #require(await transport.bodies(of: "list_messages").first)
        let decoded = try ListMessagesRequest(serializedBytes: sent)
        #expect(decoded.parentID == expected.parentID)
        #expect(decoded.pageSize == 500)
    }

    @Test func openingAThreadSaysWhetherYouFollowIt() async throws {
        let (backend, _) = try await connected([
            "list_messages": listMessages(["t-1", "r-1"]),
            "get_user_topic_metadata": metadata(muted: true)
        ])
        let log = ThreadEventLog(backend)
        _ = try await backend.loadThread(thread, in: conversation)
        let followed = await log.first {
            if case .threadChanged(_, _, .followed) = $0 {
                true
            } else {
                false
            }
        }
        #expect(followed == .threadChanged(
            threadID: thread,
            conversationID: conversation,
            change: .followed(false)
        ))
    }

    /// An answer without field 2 says nothing (ruling 8): no event, and the
    /// page still loads.
    @Test func aMetadataAnswerWithoutTheFlagEmitsNothing() async throws {
        let (backend, _) = try await connected([
            "list_messages": listMessages(["t-1", "r-1"]),
            "get_user_topic_metadata": metadata(muted: nil)
        ])
        let log = ThreadEventLog(backend)
        let page = try await backend.loadThread(thread, in: conversation)
        #expect(page.count == 2)
        try await Task.sleep(for: .milliseconds(100)) // asserting that nothing happens
        #expect(await log.threadChanges().isEmpty)
    }

    /// Asked together: both calls are in flight at once, so opening a thread
    /// costs one round trip, not two (session 58). Both are held, so no
    /// sequential order, either way round, can have both sent.
    @Test func theFollowStateIsAskedWhileThePageLoads() async throws {
        let (backend, transport) = try await connected(
            [:], holding: ["list_messages", "get_user_topic_metadata"]
        )
        let log = ThreadEventLog(backend)
        let load = Task { try await backend.loadThread(thread, in: conversation) }
        var both = false
        for _ in 0 ..< 400 {
            let page = await transport.bodies(of: "list_messages").count
            let metadata = await transport.bodies(of: "get_user_topic_metadata").count
            if page == 1, metadata == 1 {
                both = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(both)
        await transport.answer("get_user_topic_metadata", with: metadata(muted: false))
        try await transport.answer("list_messages", with: listMessages(["t-1", "r-1"]))
        let page = try await load.value
        #expect(page.count == 2)
        let followed = await log.first {
            if case .threadChanged(_, _, .followed) = $0 {
                true
            } else {
                false
            }
        }
        #expect(followed == .threadChanged(
            threadID: thread,
            conversationID: conversation,
            change: .followed(true)
        ))
    }

    /// A refused page throws, and says nothing about following, as before the
    /// two calls went out together.
    @Test func aRefusedPageSaysNothingAboutFollowing() async throws {
        let (backend, _) = try await connected(["get_user_topic_metadata": metadata(muted: false)])
        let log = ThreadEventLog(backend)
        await #expect(throws: (any Error).self) {
            _ = try await backend.loadThread(thread, in: conversation)
        }
        try await Task.sleep(for: .milliseconds(100)) // asserting that nothing happens
        #expect(await log.threadChanges().isEmpty)
    }

    // MARK: - Follow

    @Test func followingSendsMuteFalseAndSaysSoOnceAccepted() async throws {
        let (backend, transport) = try await connected(["mark_Topic_mute_state": accepted()])
        let log = ThreadEventLog(backend)
        try await backend.setThreadFollowed(true, thread: thread, in: conversation)
        let sent = try #require(await transport.bodies(of: "mark_Topic_mute_state").first)
        let decoded = try MarkTopicMuteStateRequest(serializedBytes: sent)
        #expect(decoded.topicID == topic())
        #expect(decoded.hasMute)
        #expect(decoded.mute == false)
        #expect(decoded.hasRequestHeader)
        let event = await log.first {
            if case .threadChanged(_, _, .followed) = $0 {
                true
            } else {
                false
            }
        }
        #expect(event == .threadChanged(
            threadID: thread,
            conversationID: conversation,
            change: .followed(true)
        ))
    }

    /// HTTP 200 proves nothing (`CLAUDE.md`): an empty-but-present answer
    /// without field 1 throws, and nothing is emitted.
    @Test func anAnswerWithoutFieldOneThrows() async throws {
        var writer = ProbeProtoWriter()
        writer.message(5) { $0.int64(1, 1) }
        let (backend, _) = try await connected(["mark_Topic_mute_state": writer.data])
        let log = ThreadEventLog(backend)
        await #expect(throws: ChatError.self) {
            try await backend.setThreadFollowed(false, thread: thread, in: conversation)
        }
        #expect(await log.threadChanges().isEmpty)
    }

    // MARK: - Read and unread marks

    /// One microsecond past the newest message, the conversation's rule
    /// (`readPositionOffsetMicroseconds`, `findings.md` §36, §42).
    @Test func markReadSendsOneMicrosecondPastAndSaysSo() async throws {
        let (backend, transport) = try await connected(["mark_topic_readstate": accepted(withRevision: true)])
        let log = ThreadEventLog(backend)
        try await backend.send(.markThreadRead(
            conversationID: conversation, threadID: thread, upTo: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        let sent = try #require(await transport.bodies(of: "mark_topic_readstate").first)
        let decoded = try MarkTopicReadStateRequest(serializedBytes: sent)
        #expect(decoded.topicID == topic())
        #expect(decoded.lastReadTime == 1_700_000_000_000_001)
        let event = await log.first {
            if case .threadChanged(_, _, .read) = $0 {
                true
            } else {
                false
            }
        }
        #expect(event == .threadChanged(
            threadID: thread, conversationID: conversation,
            change: .read(upTo: Date(timeIntervalSince1970: 1_700_000_000.000001))
        ))
    }

    /// Mark read is accepted on its revision, field 2 (Task 2, ruling 3).
    @Test func markReadWithoutARevisionThrows() async throws {
        let (backend, _) = try await connected(["mark_topic_readstate": accepted(withRevision: false)])
        await #expect(throws: ChatError.self) {
            try await backend.send(.markThreadRead(
                conversationID: conversation, threadID: thread, upTo: Date(timeIntervalSince1970: 1)
            ))
        }
    }

    /// "Mark as unread" on a reply sends its time minus 1 µs (§64.3).
    @Test func markUnreadSendsOneMicrosecondBefore() async throws {
        let (backend, transport) = try await connected(["set_topic_unread_timestamp": accepted()])
        try await backend.send(.setThreadUnreadMark(
            conversationID: conversation, threadID: thread, at: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        let sent = try #require(await transport.bodies(of: "set_topic_unread_timestamp").first)
        #expect(try SetTopicUnreadTimestampRequest(serializedBytes: sent)
            .unreadTimestamp == 1_699_999_999_999_999)
    }

    /// Clearing sends 0 and says the mark is gone.
    @Test func clearingSendsZero() async throws {
        let (backend, transport) = try await connected(["set_topic_unread_timestamp": accepted()])
        let log = ThreadEventLog(backend)
        try await backend.send(.setThreadUnreadMark(conversationID: conversation, threadID: thread, at: nil))
        let sent = try #require(await transport.bodies(of: "set_topic_unread_timestamp").first)
        #expect(try SetTopicUnreadTimestampRequest(serializedBytes: sent).unreadTimestamp == 0)
        let event = await log.first {
            if case .threadChanged(_, _, .markedUnread) = $0 {
                true
            } else {
                false
            }
        }
        #expect(event == .threadChanged(
            threadID: thread,
            conversationID: conversation,
            change: .markedUnread(at: nil)
        ))
    }

    /// `.markRead` still reaches `mark_group_readstate` through the shared
    /// `case` (ruling 6).
    @Test func theConversationMarkStillWorks() async throws {
        var state = GroupReadState()
        state.lastReadTime = 5
        var response = MarkGroupReadstateResponse()
        response.readState = state
        let (backend, transport) = try await connected(["mark_group_readstate": response.serializedBytes()])
        try await backend.send(.markRead(conversationID: conversation, upTo: Date(timeIntervalSince1970: 1)))
        #expect(await transport.bodies(of: "mark_group_readstate").count == 1)
    }

    // MARK: - After a sign-out

    /// A follow answered after `disconnect()` emits nothing into the next
    /// session (ruling 5).
    @Test func aLateFollowAnswerEmitsNothing() async throws {
        let (backend, transport) = try await connected([:], holding: ["mark_Topic_mute_state"])
        let log = ThreadEventLog(backend)
        let follow = Task { try await backend.setThreadFollowed(true, thread: thread, in: conversation) }
        // Wait, bounded, for the request to be held, then end the session
        // before it is answered.
        for _ in 0 ..< 200 where await transport.bodies(of: "mark_Topic_mute_state").isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await !transport.bodies(of: "mark_Topic_mute_state").isEmpty)
        await backend.disconnect()
        await transport.answer("mark_Topic_mute_state", with: accepted())
        _ = try? await follow.value
        try await Task.sleep(for: .milliseconds(100)) // asserting that nothing happens
        #expect(await log.threadChanges().isEmpty)
    }

    // MARK: - The Threads list

    @Test func theThreadsListFollowsEachThreadAndStoresItsMessages() async throws {
        var topic = Topic()
        topic.id = self.topic()
        var first = GChatBridgeCore.Message()
        first.id.messageID = "t-1"
        first.id.parentID.topicID = self.topic()
        first.creator.userID.id = "u-1"
        first.createTime = 1_700_000_000_000_000
        var reply = first
        reply.id.messageID = "r-9"
        reply.isInlineReply = true
        reply.createTime = 1_700_000_100_000_000
        topic.replies = [first, reply]
        var entity = WorldEntity()
        entity.topic = topic
        var response = PaginatedWorldResponse()
        response.worldEntities = [entity]
        let (backend, _) = try await connected(["paginated_world": response.serializedBytes()])
        let log = ThreadEventLog(backend)
        let messages = try await backend.loadFollowedThreads()
        #expect(messages.map(\.id.rawValue) == ["t-1", "r-9"])
        let followed = await log.first {
            if case .threadChanged(_, _, .followed(true)) = $0 {
                true
            } else {
                false
            }
        }
        #expect(followed != nil)
        try await Task.sleep(for: .milliseconds(100)) // asserting that nothing more happens
        let changes = await log.threadChanges()
        // One reply per topic is not the thread's count (ruling 2).
        #expect(changes.allSatisfy {
            if case .counted = $0 {
                false
            } else {
                true
            }
        })
        // The list carries no read state, so it never clears a mark (Task 6's
        // `Listing.threadsList`).
        #expect(!changes.contains(.markedUnread(at: nil)))
    }
}
