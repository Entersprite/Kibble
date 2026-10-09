import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The shell for `connect()`, and one `list_topics` answer. At file scope, as
/// `LoadMessagesTests`' own transport is: nested in the suite, its error type
/// would sit two levels deep (swiftlint's `nesting`).
private actor Routing: HTTPTransport {
    struct NoStream: Error {}
    let topics: HTTPResponse
    private(set) var sent: [HTTPRequest] = []

    init(topics: HTTPResponse) {
        self.topics = topics
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        if request.url.path.contains("/mole/world") {
            let html = LocalBridgeBackendTests.shell(app: "DynamiteWebUi")
            return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(html.utf8))
        }
        if request.url.path.contains("/api/list_topics") {
            return topics
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }
}

/// History carries replies and their threads' read state (threads spec §2.2).
@Suite(.timeLimit(.minutes(1)))
struct LoadMessagesThreadTests {
    private static let cookies = SessionCookies(header: "SID=a; COMPASS=b; OSID=c")!

    private func group() -> GroupId {
        var space = SpaceId()
        space.spaceID = "s-1"
        var group = GroupId()
        group.spaceID = space
        return group
    }

    private func message(_ id: String, reply: Bool) -> GChatBridgeCore.Message {
        var message = GChatBridgeCore.Message()
        message.id.messageID = id
        message.id.parentID.topicID.topicID = "t-1"
        message.id.parentID.topicID.groupID = group()
        message.creator.userID.id = "u-1"
        message.createTime = reply ? 1_700_000_100_000_000 : 1_700_000_000_000_000
        if reply {
            message.isInlineReply = true
        }
        return message
    }

    /// One topic listing `count` messages: its first, then replies.
    private func answer(listing count: Int = 2) throws -> HTTPResponse {
        var topic = Topic()
        topic.id.topicID = "t-1"
        topic.id.groupID = group()
        topic.replies = [message("t-1", reply: false)] + (1 ..< count).map { message("r-\($0)", reply: true) }
        topic.topicReadState.lastReadTime = 1_700_000_000_000_000
        var response = ListTopicsResponse()
        response.topics = [topic]
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    @Test func aPageCarriesTheReplyMarkedAsOne() async throws {
        let backend = try LocalBridgeBackend(cookies: Self.cookies, transport: Routing(topics: answer()))
        try await backend.connect()
        let page = try await backend.loadMessages(in: Conversation.ID("space/s-1"), before: nil)
        #expect(page.map(\.isReply) == [false, true])
    }

    @Test func itEmitsTheThreadsReadState() async throws {
        let backend = try LocalBridgeBackend(cookies: Self.cookies, transport: Routing(topics: answer()))
        let log = ThreadEventLog(backend)
        try await backend.connect()
        _ = try await backend.loadMessages(in: Conversation.ID("space/s-1"), before: nil)
        let read = await log.first {
            if case .threadChanged(_, _, .read) = $0 {
                true
            } else {
                false
            }
        }
        #expect(read == .threadChanged(
            threadID: MessageThread.ID("t-1"), conversationID: Conversation.ID("space/s-1"),
            change: .read(upTo: Date(timeIntervalSince1970: 1_700_000_000))
        ))
    }

    /// The request is rung 3: replies come with their first message.
    @Test func itAsksForReplies() async throws {
        let transport = try Routing(topics: answer())
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()
        _ = try await backend.loadMessages(in: Conversation.ID("space/s-1"), before: nil)
        let request = try #require(await transport.sent.first { $0.url.path.contains("/api/list_topics") })
        let expected: Data = try TopicsRequestLadder.history(for: group()).request.serializedBytes()
        #expect(request.body == expected)
    }

    // MARK: - A page of replies may be cut short

    /// The event log of one history load, for a topic listing `count`
    /// messages without fields 10 and 14. Each test waits, bounded, for the
    /// event it asserts on.
    private func historyLoad(listing count: Int) async throws -> ThreadEventLog {
        let backend = try LocalBridgeBackend(
            cookies: Self.cookies,
            transport: Routing(topics: answer(listing: count))
        )
        let log = ThreadEventLog(backend)
        try await backend.connect()
        _ = try await backend.loadMessages(in: Conversation.ID("space/s-1"), before: nil)
        return log
    }

    /// Rung 3 asks for at most 50 replies, and `.counted` replaces the stored
    /// count, so a listing that reaches the cap may be a longer thread cut
    /// short: without field 10 it counts nothing. The read position comes
    /// after the count in `ThreadMapping`'s order, so once it has arrived a
    /// count would have too: the positive control for asserting none came.
    @Test func aListingThatReachesTheCapIsNotCounted() async throws {
        let log = try await historyLoad(listing: 50)
        let read = await log.first {
            if case .threadChanged(_, _, .read) = $0 {
                true
            } else {
                false
            }
        }
        try #require(read != nil)
        #expect(await !log.threadChanges().contains {
            if case .counted = $0 {
                true
            } else {
                false
            }
        })
    }

    @Test func aListingUnderTheCapIsCounted() async throws {
        let log = try await historyLoad(listing: 49)
        let counted = await log.first {
            if case .threadChanged(_, _, .counted) = $0 {
                true
            } else {
                false
            }
        }
        #expect(counted == .threadChanged(
            threadID: MessageThread.ID("t-1"), conversationID: Conversation.ID("space/s-1"),
            change: .counted(messages: 49, unread: nil)
        ))
    }

    /// A count the cap may have cut short does not make the read state less
    /// of a snapshot: no field 14 still clears a stale mark (ruling 3).
    @Test func aListingThatReachesTheCapStillClearsTheMark() async throws {
        let log = try await historyLoad(listing: 50)
        let cleared = await log.first {
            if case .threadChanged(_, _, .markedUnread(at: nil)) = $0 {
                true
            } else {
                false
            }
        }
        #expect(cleared != nil)
    }
}
