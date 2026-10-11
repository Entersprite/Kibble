import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The shell (with what `batchexecute` needs), the self lookup, and queued
/// `list_topics` and `batchexecute` answers. At file scope for the reason
/// `LoadMessagesThreadTests`' own transport gives, and duplicated rather than
/// shared, as every transport fake in this suite is.
private actor AnchorTransport: HTTPTransport {
    struct NoStream: Error {}
    struct Exhausted: Error {}

    private var topics: [HTTPResponse]
    private var batches: [HTTPResponse]
    private(set) var sent: [HTTPRequest] = []

    init(topics: [HTTPResponse], batches: [HTTPResponse] = []) {
        self.topics = topics
        self.batches = batches
    }

    var listTopicsRequests: [HTTPRequest] {
        sent.filter { $0.url.path.contains("/api/list_topics") }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        let path = request.url.path
        if path.contains("/mole/world") {
            return SearchFixtures.fullShell()
        }
        if path.contains("/api/get_self_user_status") {
            return SearchTransport.selfStatusResponse("u-me")
        }
        if path.contains("/api/get_members") {
            return SearchTransport.emptyMembersResponse
        }
        if path.contains("/api/list_topics") {
            guard !topics.isEmpty else { throw Exhausted() }
            return topics.removeFirst()
        }
        if path.contains("batchexecute") {
            guard !batches.isEmpty else { throw Exhausted() }
            return batches.removeFirst()
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }
}

/// History anchored on a known message's own time (`findings.md` §65.9): the
/// request, the filter that keeps only what is older, and the memory of
/// create times that history, pushes and search hits fill.
@Suite(.timeLimit(.minutes(1)))
struct LoadMessagesAnchorTests {
    private static let cookies = SessionCookies(header: "SID=a; COMPASS=b; OSID=c")!
    private static let space = Conversation.ID("space/s-1")
    /// 16 digits and no whole millisecond, so a path through milliseconds
    /// could not produce it.
    private static let anchor: Int64 = 1_790_123_456_789_012

    private static func group(_ id: String = "s-1") -> GroupId {
        var group = GroupId()
        group.spaceID.spaceID = id
        return group
    }

    private static func message(
        _ id: String, at micros: Int64, topic: String? = nil, reply: Bool = false
    ) -> GChatBridgeCore.Message {
        var message = GChatBridgeCore.Message()
        message.id.messageID = id
        message.id.parentID.topicID.topicID = topic ?? id
        message.id.parentID.topicID.groupID = group()
        message.creator.userID.id = "u-1"
        message.createTime = micros
        if reply {
            message.isInlineReply = true
        }
        return message
    }

    private static func topic(_ messages: [GChatBridgeCore.Message], readAt: Int64? = nil) -> Topic {
        var topic = Topic()
        topic.id.topicID = messages.first?.id.parentID.topicID.topicID ?? ""
        topic.id.groupID = group()
        topic.replies = messages
        if let readAt {
            topic.topicReadState.lastReadTime = readAt
        }
        return topic
    }

    private static func answer(_ topics: [Topic]) throws -> HTTPResponse {
        var response = ListTopicsResponse()
        response.topics = topics
        // An empty answer serializes to zero bytes, which `ProtoAPIClient`
        // reports as an empty body; a flag keeps it decodable.
        response.containsFirstTopic = topics.isEmpty
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    /// A newest page holding the anchor message, then `then`.
    private static func connected(then: [HTTPResponse] = [], batches: [HTTPResponse] = []) async throws
        -> (LocalBridgeBackend, AnchorTransport) {
        let first = try answer([topic([message("m-anchor", at: anchor)])])
        let transport = AnchorTransport(topics: [first] + then, batches: batches)
        let backend = LocalBridgeBackend(cookies: cookies, transport: transport)
        try await backend.connect()
        return (backend, transport)
    }

    // MARK: - The request

    @Test func aKnownMessageAnchorsThePageOnItsOwnTimeAndSortsTwo() async throws {
        let (backend, transport) = try await Self.connected(then: [Self.answer([])])
        _ = try await backend.loadMessages(in: Self.space, before: nil)
        _ = try await backend.loadMessages(in: Self.space, before: ChatKit.Message.ID("m-anchor"))

        let sent = try #require(await transport.listTopicsRequests.last?.body)
        let request = try ListTopicsRequest(serializedBytes: sent)
        #expect(request.filter.anchor.timeUsec == Self.anchor)
        #expect(request.sortOption == 2)
        // Otherwise history's own request: built by hand here, not through
        // the builder the bridge calls.
        var expected = TopicsRequestLadder.history(for: Self.group()).request
        expected.filter.anchor.timeUsec = Self.anchor
        expected.sortOption = 2
        let expectedBytes: Data = try expected.serializedBytes()
        #expect(sent == expectedBytes)
    }

    /// A message this session never mapped has no known time, so the page is
    /// the newest one, exactly the request plain history sends.
    @Test func anUnknownMessageSendsThePlainNewestPage() async throws {
        let (backend, transport) = try await Self.connected(then: [Self.answer([])])
        _ = try await backend.loadMessages(in: Self.space, before: nil)
        _ = try await backend.loadMessages(in: Self.space, before: ChatKit.Message.ID("never-seen"))

        let sent = try #require(await transport.listTopicsRequests.last?.body)
        let expected: Data = try TopicsRequestLadder.history(for: Self.group()).request.serializedBytes()
        #expect(sent == expected)
    }

    // MARK: - Only what is older comes back

    /// Whether the server pages from the anchor is `[Verify]` (§65.9: every
    /// captured answer reached the newest topic), so the bridge keeps only
    /// what is strictly older, to the microsecond: the anchor itself, a
    /// message at the very same microsecond and anything newer stay out.
    @Test func onlyMessagesOlderThanTheAnchorComeBack() async throws {
        let mixed = try Self.answer([
            Self.topic([Self.message("older", at: Self.anchor - 1)]),
            Self.topic([Self.message("same-time", at: Self.anchor)]),
            Self.topic([Self.message("m-anchor", at: Self.anchor)]),
            Self.topic([Self.message("newer", at: Self.anchor + 1)])
        ])
        let (backend, _) = try await Self.connected(then: [mixed])
        _ = try await backend.loadMessages(in: Self.space, before: nil)
        let page = try await backend.loadMessages(in: Self.space, before: ChatKit.Message.ID("m-anchor"))
        #expect(page.map(\.id.rawValue) == ["older"])
    }

    /// The server's answer about a thread is a snapshot whatever the filter
    /// keeps, so a topic newer than the anchor still reports its read state.
    @Test func aTopicNewerThanTheAnchorStillReportsItsThread() async throws {
        let newer = [
            Self.message("t-new", at: Self.anchor + 5),
            Self.message("r-new", at: Self.anchor + 6, topic: "t-new", reply: true)
        ]
        let answer = try Self.answer([Self.topic(newer, readAt: Self.anchor + 6)])
        let (backend, _) = try await Self.connected(then: [answer])
        let log = ThreadEventLog(backend)
        _ = try await backend.loadMessages(in: Self.space, before: nil)
        let page = try await backend.loadMessages(in: Self.space, before: ChatKit.Message.ID("m-anchor"))
        #expect(page.isEmpty)
        let read = await log.first {
            if case let .threadChanged(thread, _, .read) = $0 {
                thread == MessageThread.ID("t-new")
            } else {
                false
            }
        }
        #expect(read != nil)
    }

    // MARK: - What fills the memory, and what empties it

    @Test func aHistoryPageIsRemembered() async throws {
        let (backend, _) = try await Self.connected()
        _ = try await backend.loadMessages(in: Self.space, before: nil)
        #expect(await backend.messageTimes.micros(of: ChatKit.Message.ID("m-anchor")) == Self.anchor)
    }

    /// A hit's time is its own field 12, in microseconds (§65.8), and it is
    /// what an opened hit's page anchors on.
    @Test func aSearchHitAnchorsItsPage() async throws {
        let hit = SearchFixtures.hit(
            messageID: "hit-1", spaceID: "s-1", senderID: "u-1", text: "x", createdAtMicros: Self.anchor - 7
        )
        let inner = SearchFixtures.pageInner(nextToken: nil, hits: [hit])
        let batch = try HTTPResponse(
            status: 200, headers: HTTPHeaders([]), body: SearchFixtures.answerBody(inner: inner)
        )
        let (backend, transport) = try await Self.connected(then: [Self.answer([])], batches: [batch])
        try await SearchBackendSupport.waitForSelf(backend)
        let page = try await backend.searchMessages(MessageSearchQuery(text: "x"), after: nil)
        #expect(page.hits.map(\.id.rawValue) == ["hit-1"])
        _ = try await backend.loadMessages(in: Self.space, before: ChatKit.Message.ID("hit-1"))

        let sent = try #require(await transport.listTopicsRequests.last?.body)
        #expect(try ListTopicsRequest(serializedBytes: sent).filter.anchor.timeUsec == Self.anchor - 7)
    }

    /// A `MESSAGE_POSTED` chunk in `LiveChannelTests`' shape, at `micros`.
    private static func pushChunk(aid: Int, micros: Int64) -> String {
        let group = #"[null,null,["dm-1"]]"#
        let topic = #"[null,"t-1",\#(group)]"#
        let parent = "[null,null,null,\(topic)]"
        let identifier = #"[\#(parent),"m-\#(aid)"]"#
        let padding = Array(repeating: "null", count: 6).joined(separator: ",")
        let message = #"[\#(identifier),[["u-1"]],"\#(micros)",\#(padding),"pushed"]"#
        let body = "[null,null,null,null,null,[\(message)],null,null,null,null,null,6]"
        let event = "[null,null,null,null,null,null,null,[\(body)]]"
        let payload = #"[[\#(event),"wrapper"]]"#
        let array = "[[\(aid),\(payload)]]"
        return "\(array.utf16.count)\n\(array)"
    }

    @Test func aPushedMessageIsRemembered() async throws {
        let initial = #"[[0,["c","S3ss10n","",8,12,30000]]]"#
        let transport = ScriptedTransport(
            [ScriptedTransport.ok(LocalBridgeBackendTests.shell(app: "DynamiteWebUi"))]
                + Array(repeating: ScriptedTransport.ok(""), count: 5),
            streams: [ScriptedTransport.Script(
                headers: HTTPHeaders([("X-HTTP-Initial-Response", initial)]),
                chunks: [Self.pushChunk(aid: 1, micros: Self.anchor)]
            )]
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()
        let id = ChatKit.Message.ID("m-1")
        for _ in 0 ..< 400 where await backend.messageTimes.micros(of: id) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await backend.messageTimes.micros(of: id) == Self.anchor)
        await backend.disconnect()
    }

    @Test func disconnectForgetsEveryTime() async throws {
        let (backend, transport) = try await Self.connected(then: [Self.answer([])])
        _ = try await backend.loadMessages(in: Self.space, before: nil)
        try #require(await !backend.messageTimes.isEmpty)
        await backend.disconnect()
        #expect(await backend.messageTimes.isEmpty)
        // So a new session asks for the newest page, not an old session's anchor.
        try await backend.connect()
        _ = try await backend.loadMessages(in: Self.space, before: ChatKit.Message.ID("m-anchor"))
        let sent = try #require(await transport.listTopicsRequests.last?.body)
        let expected: Data = try TopicsRequestLadder.history(for: Self.group()).request.serializedBytes()
        #expect(sent == expected)
        await backend.disconnect()
    }
}
