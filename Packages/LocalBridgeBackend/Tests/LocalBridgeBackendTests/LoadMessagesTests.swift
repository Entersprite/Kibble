import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `loadMessages(in:before:)`, reached through a real `connect()` - the same
/// shape `LoadConversationsMemberResolutionTests.swift` uses for
/// `loadConversations()`.
///
/// `RoutingTransport` is duplicated rather than shared, the same call that
/// file's own doc comment on its own `RoutingTransport` already makes:
/// `private` is `private`, and a little duplication is cheaper than a shared
/// surface neither file actually needs elsewhere.
private actor RoutingTransport: HTTPTransport {
    struct NoStream: Error {}

    private let shell: HTTPResponse
    private let listTopicsResponse: HTTPResponse
    private let listTopicsFailure: (any Error)?
    private(set) var sent: [HTTPRequest] = []

    init(
        shell: HTTPResponse,
        listTopicsResponse: HTTPResponse,
        listTopicsFailure: (any Error)? = nil
    ) {
        self.shell = shell
        self.listTopicsResponse = listTopicsResponse
        self.listTopicsFailure = listTopicsFailure
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        if request.url.path.contains("/mole/world") {
            return shell
        }
        if request.url.path.contains("/api/list_topics") {
            if let listTopicsFailure {
                throw listTopicsFailure
            }
            return listTopicsResponse
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct LoadMessagesTests {
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

    private func topicsResponse(_ topics: [Topic]) throws -> HTTPResponse {
        var response = ListTopicsResponse()
        response.topics = topics
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    private func topic(replies: [GChatBridgeCore.Message]) -> Topic {
        var topic = Topic()
        topic.replies = replies
        return topic
    }

    private func backend(_ transport: RoutingTransport) -> LocalBridgeBackend {
        LocalBridgeBackend(cookies: Self.cookies, transport: transport)
    }

    private func collectEvents(
        _ backend: LocalBridgeBackend,
        for duration: Duration = .milliseconds(200)
    ) async -> [ChatEvent] {
        let collector = Task<[ChatEvent], Never> {
            var events: [ChatEvent] = []
            for await event in backend.events {
                events.append(event)
            }
            return events
        }
        try? await Task.sleep(for: duration)
        collector.cancel()
        return await collector.value
    }

    // MARK: - Before connect

    @Test func loadMessagesBeforeConnectFailsClearly() async throws {
        let backend = try backend(RoutingTransport(
            shell: shellResponse(),
            listTopicsResponse: topicsResponse([])
        ))
        await #expect(throws: ChatError.self) {
            _ = try await backend.loadMessages(in: Conversation.ID("space/s-1"), before: nil)
        }
    }

    @Test func loadMessagesBeforeConnectNamesWhatIsMissing() async throws {
        let backend = try backend(RoutingTransport(
            shell: shellResponse(),
            listTopicsResponse: topicsResponse([])
        ))
        do {
            _ = try await backend.loadMessages(in: Conversation.ID("space/s-1"), before: nil)
            Issue.record("expected loadMessages(in:before:) to throw before connect()")
        } catch {
            #expect(String(describing: error).lowercased().contains("connect"))
        }
    }

    // MARK: - After connect: the real call

    @Test func loadMessagesReturnsTheMappedMessagesOldestToNewest() async throws {
        let group = spaceGroupID("s-1")
        let response = try topicsResponse([
            topic(replies: [reply(id: "m-new", groupID: group, createTimeMicros: 2000)]),
            topic(replies: [reply(id: "m-old", groupID: group, createTimeMicros: 1000)])
        ])
        let backend = backend(RoutingTransport(shell: shellResponse(), listTopicsResponse: response))
        try await backend.connect()

        let messages = try await backend.loadMessages(in: Conversation.ID("space/s-1"), before: nil)
        #expect(messages.map(\.id.rawValue) == ["m-old", "m-new"])
    }

    /// `before:` has no cursor to spend on the wire, so it is ignored and the
    /// first page always comes back - asserted by passing a non-nil value
    /// and getting the identical result `nil` would.
    @Test func loadMessagesIgnoresBeforeAndReturnsTheFirstPage() async throws {
        let group = spaceGroupID("s-1")
        let response = try topicsResponse([
            topic(replies: [reply(id: "m-1", groupID: group)])
        ])
        let backend = backend(RoutingTransport(shell: shellResponse(), listTopicsResponse: response))
        try await backend.connect()

        let messages = try await backend.loadMessages(
            in: Conversation.ID("space/s-1"),
            before: ChatKit.Message.ID("some-cursor-that-does-not-exist")
        )
        #expect(messages.map(\.id.rawValue) == ["m-1"])
    }

    /// The request actually sent is `TopicsRequestLadder.minimumViable(for:)`
    /// for the conversation's own group - never a different shape, and never
    /// the whole four-rung ladder.
    @Test func loadMessagesSendsTheMinimumViableRungForTheConversationsGroup() async throws {
        let group = spaceGroupID("s-1")
        // An empty `ListTopicsResponse` serializes to zero bytes, which
        // `ProtoAPIClient.call` reports as `.emptyBody` rather than a decoded
        // value - this test only cares what was *sent*, so one harmless flag
        // gives the response a non-empty body to decode.
        var emptyButNonZero = ListTopicsResponse()
        emptyButNonZero.containsFirstTopic = true
        let response = try HTTPResponse(
            status: 200,
            headers: HTTPHeaders([]),
            body: emptyButNonZero.serializedBytes()
        )
        let transport = RoutingTransport(shell: shellResponse(), listTopicsResponse: response)
        let backend = backend(transport)
        try await backend.connect()
        _ = try await backend.loadMessages(in: Conversation.ID("space/s-1"), before: nil)

        let sent = await transport.sent
        let listTopicsRequest = try #require(sent.first { $0.url.path.contains("/api/list_topics") })
        let expected: Data = try TopicsRequestLadder.minimumViable(for: group).request.serializedBytes()
        #expect(listTopicsRequest.body == expected)
    }

    @Test func loadMessagesEmitsABackendErrorWhenMessagesAreSkipped() async throws {
        let group = spaceGroupID("s-1")
        let response = try topicsResponse([
            topic(replies: [
                reply(id: "m-1", groupID: group),
                reply(id: "", groupID: group)
            ])
        ])
        let backend = backend(RoutingTransport(shell: shellResponse(), listTopicsResponse: response))
        try await backend.connect()

        let messages = try await backend.loadMessages(in: Conversation.ID("space/s-1"), before: nil)
        #expect(messages.count == 1)

        let events = await collectEvents(backend)
        let found = events.contains {
            if case let .backendError(error) = $0, case let .unknown(message) = error {
                message.contains("1 message")
            } else {
                false
            }
        }
        #expect(found)
    }

    @Test func loadMessagesFailsForAConversationIDWithNeitherPrefix() async throws {
        let backend = try backend(RoutingTransport(
            shell: shellResponse(),
            listTopicsResponse: topicsResponse([])
        ))
        try await backend.connect()

        do {
            _ = try await backend.loadMessages(in: Conversation.ID("space:1"), before: nil)
            Issue.record("expected loadMessages(in:before:) to throw for an unprefixed id")
        } catch {
            #expect(String(describing: error).contains("space:1"))
        }
    }

    @Test func loadMessagesWrapsAListTopicsFailureAsAChatError() async throws {
        struct Boom: Error {}
        let backend = try backend(RoutingTransport(
            shell: shellResponse(),
            listTopicsResponse: topicsResponse([]),
            listTopicsFailure: Boom()
        ))
        try await backend.connect()

        await #expect(throws: ChatError.self) {
            _ = try await backend.loadMessages(in: Conversation.ID("space/s-1"), before: nil)
        }
    }
}
