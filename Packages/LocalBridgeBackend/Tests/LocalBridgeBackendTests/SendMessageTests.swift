import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `send(_:)` for `.sendMessage`, reached through a real `connect()` - the same
/// shape `LoadMessagesTests.swift` uses for `loadMessages(in:before:)`.
///
/// `RoutingTransport` is duplicated rather than shared, the same call that
/// file's own doc comment on its own `RoutingTransport` already makes:
/// `private` is `private`, and a little duplication is cheaper than a shared
/// surface neither file actually needs elsewhere.
private actor RoutingTransport: HTTPTransport {
    struct NoStream: Error {}

    private let shell: HTTPResponse
    private let createTopicResponse: HTTPResponse
    private let createTopicFailure: (any Error)?
    private let createMessageResponse: HTTPResponse
    private(set) var sent: [HTTPRequest] = []

    init(
        shell: HTTPResponse,
        createTopicResponse: HTTPResponse,
        createTopicFailure: (any Error)? = nil,
        createMessageResponse: HTTPResponse = HTTPResponse(
            status: 200,
            headers: HTTPHeaders([]),
            body: Data()
        )
    ) {
        self.shell = shell
        self.createTopicResponse = createTopicResponse
        self.createTopicFailure = createTopicFailure
        self.createMessageResponse = createMessageResponse
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        if request.url.path.contains("/mole/world") {
            return shell
        }
        if request.url.path.contains("/api/create_topic") {
            if let createTopicFailure {
                throw createTopicFailure
            }
            return createTopicResponse
        }
        if request.url.path.contains("/api/create_message") {
            return createMessageResponse
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SendMessageTests {
    private static let cookies = SessionCookies(header: "SID=a; COMPASS=b; OSID=c")!

    private func shellResponse(app: String = "DynamiteWebUi") -> HTTPResponse {
        let html = LocalBridgeBackendTests.shell(app: app)
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(html.utf8))
    }

    private func spaceGroupID(_ id: String) -> GroupId {
        var group = GroupId()
        var space = SpaceId()
        space.spaceID = id
        group.spaceID = space
        return group
    }

    private func reply(
        id: String,
        groupID: GroupId,
        topicID: String = "t-1",
        senderID: String = "u-1",
        text: String = "hello",
        createTimeMicros: Int64 = 1_700_000_000_000_000
    ) -> GChatBridgeCore.Message {
        var topic = TopicId()
        topic.groupID = groupID
        topic.topicID = topicID
        var parent = MessageParentId()
        parent.topicID = topic
        var messageID = MessageId()
        messageID.parentID = parent
        messageID.messageID = id
        var creator = User()
        var userID = UserId()
        userID.id = senderID
        creator.userID = userID

        var message = GChatBridgeCore.Message()
        message.id = messageID
        message.creator = creator
        message.textBody = text
        message.createTime = createTimeMicros
        return message
    }

    /// Builds a well-formed `Topic`: an id (field 1 of the id message) plus
    /// one reply. Task 11's `requireAccepted` check reads `topic.id.topicID`,
    /// so a fixture that only ever set `replies` - as this helper did before
    /// that check existed - was never actually well-formed; it happened to
    /// pass only because nothing looked at the id before now.
    private func topicWithReply(id: String, groupID: GroupId) -> Topic {
        var topic = Topic()
        var topicID = TopicId()
        topicID.groupID = groupID
        topicID.topicID = id
        topic.id = topicID
        topic.replies = [reply(id: id, groupID: groupID)]
        return topic
    }

    /// A `CreateMessageResponse` with one field set. An entirely empty
    /// message serialises to zero bytes, which `ProtoAPIClient.call` reports
    /// as `.emptyBody` rather than a decoded value - these tests only care
    /// what was *sent*, so one harmless field is enough to let the call
    /// succeed and reach the assertion on `transport.sent`.
    private func nonEmptyCreateMessageResponse(groupID: GroupId) throws -> HTTPResponse {
        var response = CreateMessageResponse()
        response.message = reply(id: "m-2", groupID: groupID)
        return try HTTPResponse(
            status: 200, headers: HTTPHeaders([]), body: response.serializedBytes()
        )
    }

    private func backend(_ transport: RoutingTransport) -> LocalBridgeBackend {
        LocalBridgeBackend(cookies: Self.cookies, transport: transport)
    }

    /// The bytes on the wire are `SendRequests.createTopic`'s own
    /// serialisation, so an edit that changes what production sends cannot pass
    /// silently. Same shape as `LoadMessagesTests`'s equivalent assertion.
    @Test func sendPostsTheCreateTopicShapeForAFlatConversation() async throws {
        var response = CreateTopicResponse()
        response.topic = topicWithReply(id: "m-1", groupID: spaceGroupID("s-1"))
        let transport = try RoutingTransport(
            shell: shellResponse(),
            createTopicResponse: HTTPResponse(
                status: 200, headers: HTTPHeaders([]), body: response.serializedBytes()
            )
        )
        let backend = backend(transport)
        try await backend.connect()
        try await backend.send(.sendMessage(
            conversationID: Conversation.ID("space/s-1"),
            threadID: nil,
            text: "hello",
            localID: "gchat%7"
        ))

        let sent = await transport.sent
        let request = try #require(sent.first { $0.url.path.contains("/api/create_topic") })
        let expected: Data = try SendRequests.createTopic(
            group: spaceGroupID("s-1"), text: "hello", localID: "gchat%7"
        ).serializedBytes()
        #expect(request.body == expected)
    }

    /// A send with no `localID` still gets one. The server echoes it back and
    /// it is the only thing that identifies the echo as ours; leaving it empty
    /// would make every optimistic copy unmatchable.
    @Test func sendGeneratesALocalIDWhenTheCommandCarriesNone() async throws {
        var response = CreateTopicResponse()
        response.topic = topicWithReply(id: "m-1", groupID: spaceGroupID("s-1"))
        let transport = try RoutingTransport(
            shell: shellResponse(),
            createTopicResponse: HTTPResponse(
                status: 200, headers: HTTPHeaders([]), body: response.serializedBytes()
            )
        )
        let backend = backend(transport)
        try await backend.connect()
        try await backend.send(.sendMessage(
            conversationID: Conversation.ID("space/s-1"),
            threadID: nil,
            text: "hello",
            localID: nil
        ))

        let sent = await transport.sent
        let request = try #require(sent.first { $0.url.path.contains("/api/create_topic") })
        let body = try #require(request.body)
        let decoded = try CreateTopicRequest(serializedBytes: body)
        #expect(!decoded.localID.isEmpty)
    }

    /// An unprefixed conversation id cannot become a `GroupId`, and failing
    /// before the network is what keeps a typo from looking like an outage.
    @Test func sendFailsForAConversationIDWithNeitherPrefix() async throws {
        let backend = backend(RoutingTransport(
            shell: shellResponse(),
            createTopicResponse: HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
        ))
        try await backend.connect()

        do {
            try await backend.send(.sendMessage(
                conversationID: Conversation.ID("space:1"),
                threadID: nil, text: "x", localID: nil
            ))
            Issue.record("expected send to throw for an unprefixed id")
        } catch {
            #expect(String(describing: error).contains("space:1"))
        }
    }

    /// The composer must not offer a button that silently drops text.
    @Test func theBridgeNowAdvertisesThatItCanSend() {
        let backend = backend(RoutingTransport(
            shell: shellResponse(),
            createTopicResponse: HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
        ))
        #expect(backend.capabilities.canSendMessages)
    }

    /// Commands this backend still cannot honour keep saying so by name.
    @Test func everyOtherCommandStillNamesWhatIsMissing() async throws {
        let backend = backend(RoutingTransport(
            shell: shellResponse(),
            createTopicResponse: HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
        ))
        try await backend.connect()
        await #expect(throws: ChatError.self) {
            try await backend.send(.setTyping(
                conversationID: Conversation.ID("space/s-1"), threadID: nil, isTyping: true
            ))
        }
    }

    // MARK: - Failure is wrapped, not swallowed

    /// The equivalent of `LoadMessagesTests.loadMessagesWrapsAListTopicsFailureAsAChatError`
    /// for the write path: `createTopicFailure` exists on `RoutingTransport`
    /// specifically for this, and until now nothing supplied it.
    @Test func sendWrapsACreateTopicFailureAsAChatError() async throws {
        struct Boom: Error {}
        let backend = backend(RoutingTransport(
            shell: shellResponse(),
            createTopicResponse: HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data()),
            createTopicFailure: Boom()
        ))
        try await backend.connect()

        await #expect(throws: ChatError.self) {
            try await backend.send(.sendMessage(
                conversationID: Conversation.ID("space/s-1"), threadID: nil, text: "x", localID: nil
            ))
        }
    }

    // MARK: - Branch selection: create_topic vs. create_message

    /// A genuinely non-empty `threadID` is a reply, and must reach
    /// `create_message` carrying the thread it replies into - not
    /// `create_topic`, which would start a new thread instead of continuing
    /// the one the caller named.
    @Test func sendWithANonEmptyThreadIDRoutesToCreateMessage() async throws {
        let group = spaceGroupID("s-1")
        let transport = try RoutingTransport(
            shell: shellResponse(),
            createTopicResponse: HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data()),
            createMessageResponse: nonEmptyCreateMessageResponse(groupID: group)
        )
        let backend = backend(transport)
        try await backend.connect()
        try await backend.send(.sendMessage(
            conversationID: Conversation.ID("space/s-1"),
            threadID: MessageThread.ID("t-9"),
            text: "reply",
            localID: "gchat%3"
        ))

        let sent = await transport.sent
        let request = try #require(sent.first { $0.url.path.contains("/api/create_message") })
        let expected: Data = try SendRequests.createMessage(
            group: group, topicID: "t-9", text: "reply", localID: "gchat%3"
        ).serializedBytes()
        #expect(request.body == expected)
        #expect(!sent.contains { $0.url.path.contains("/api/create_topic") })
    }

    /// `ChannelEventMapping.swift` always produces a non-`nil` `MessageThread.ID`
    /// (a flat conversation's topic still has one), so an empty-but-non-`nil`
    /// `threadID` is the case a UI hits every time it round-trips a flat
    /// message's thread id into a reply. It must still fall through to
    /// `create_topic` - the emptiness check in `send(_:)` is what makes that
    /// true, not just the `nil` check.
    @Test func sendWithAnEmptyButNonNilThreadIDFallsThroughToCreateTopic() async throws {
        let group = spaceGroupID("s-1")
        var response = CreateTopicResponse()
        response.topic = topicWithReply(id: "m-1", groupID: group)
        let transport = try RoutingTransport(
            shell: shellResponse(),
            createTopicResponse: HTTPResponse(
                status: 200, headers: HTTPHeaders([]), body: response.serializedBytes()
            )
        )
        let backend = backend(transport)
        try await backend.connect()
        try await backend.send(.sendMessage(
            conversationID: Conversation.ID("space/s-1"),
            threadID: MessageThread.ID(""),
            text: "hello",
            localID: "gchat%4"
        ))

        let sent = await transport.sent
        #expect(sent.contains { $0.url.path.contains("/api/create_topic") })
        #expect(!sent.contains { $0.url.path.contains("/api/create_message") })
    }

    // MARK: - The response is read, not discarded

    /// **Auth failure returns HTTP 200 on this protocol**, so "did not throw"
    /// has never been proof of acceptance - and the optimistic row stays on
    /// screen regardless, which makes a silently rejected message look exactly
    /// like a sent one.
    ///
    /// The shape checked against is the one that was actually observed:
    /// `1:2:NNN|2:2:18` on all seven sends in `trace-run3-outage.csv`
    /// (session 19 §8), i.e. a populated `topic` in field 1.
    @Test func aCreateTopicWithNoTopicThrows() async throws {
        var empty = CreateTopicResponse()
        empty.groupRevision = WriteRevision()
        let transport = try RoutingTransport(
            shell: shellResponse(),
            createTopicResponse: HTTPResponse(
                status: 200, headers: HTTPHeaders([]), body: empty.serializedBytes()
            )
        )
        let backend = backend(transport)
        try await backend.connect()
        await #expect(throws: (any Error).self) {
            try await backend.send(.sendMessage(
                conversationID: Conversation.ID("space/s-1"),
                threadID: nil,
                text: "hello",
                localID: "local-1"
            ))
        }
    }

    /// A `topic` that is present but carries no id is the same failure: there
    /// is no message to have been accepted.
    @Test func aCreateTopicWhoseTopicHasNoIDThrows() async throws {
        var response = CreateTopicResponse()
        response.topic = Topic()
        let transport = try RoutingTransport(
            shell: shellResponse(),
            createTopicResponse: HTTPResponse(
                status: 200, headers: HTTPHeaders([]), body: response.serializedBytes()
            )
        )
        let backend = backend(transport)
        try await backend.connect()
        await #expect(throws: (any Error).self) {
            try await backend.send(.sendMessage(
                conversationID: Conversation.ID("space/s-1"),
                threadID: nil,
                text: "hello",
                localID: "local-1"
            ))
        }
    }

    @Test func aCreateMessageWithNoMessageThrows() async throws {
        var empty = CreateMessageResponse()
        empty.groupRevision = WriteRevision()
        let transport = try RoutingTransport(
            shell: shellResponse(),
            createTopicResponse: HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data()),
            createMessageResponse: HTTPResponse(
                status: 200, headers: HTTPHeaders([]), body: empty.serializedBytes()
            )
        )
        let backend = backend(transport)
        try await backend.connect()
        await #expect(throws: (any Error).self) {
            try await backend.send(.sendMessage(
                conversationID: Conversation.ID("space/s-1"),
                threadID: MessageThread.ID("t-1"),
                text: "hello",
                localID: "local-1"
            ))
        }
    }
}
