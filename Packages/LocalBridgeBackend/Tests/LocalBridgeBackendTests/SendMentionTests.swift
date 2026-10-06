import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

private actor MentionTransport: HTTPTransport {
    struct NoStream: Error {}
    private let shell: HTTPResponse
    private let created: HTTPResponse
    private let people: HTTPResponse
    private(set) var sent: [HTTPRequest] = []

    init(shell: HTTPResponse, created: HTTPResponse, people: HTTPResponse) {
        self.shell = shell
        self.created = created
        self.people = people
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        if request.url.path.contains("/mole/world") {
            return shell
        }
        if request.url.path.contains("/api/create_topic") {
            return created
        }
        if request.url.path.contains("/api/get_members") {
            return people
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }
}

/// A sent mention carries the person's email in `invitee_info` (`findings.md`
/// §56.2), from this session's directory or one lookup at send time.
@Suite(.timeLimit(.minutes(1)))
struct SendMentionTests {
    private static let cookies = SessionCookies(header: "SID=a; COMPASS=b; OSID=c")!
    private static let mention = Mention(target: .user(ChatKit.Member.ID("u-1")), start: 0, length: 5)

    private static func shell() -> HTTPResponse {
        HTTPResponse(
            status: 200,
            headers: HTTPHeaders([]),
            body: Data(LocalBridgeBackendTests.shell(app: "DynamiteWebUi").utf8)
        )
    }

    /// `requireAccepted` reads `topic.id.topicID`, so that is all this sets.
    private static func created() throws -> HTTPResponse {
        var topicID = TopicId()
        topicID.topicID = "t-1"
        var topic = Topic()
        topic.id = topicID
        var response = CreateTopicResponse()
        response.topic = topic
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    private static func people(_ ids: [String]) throws -> HTTPResponse {
        var response = GetMembersResponse()
        response.members = ids.map { id in
            var userID = UserId()
            userID.id = id
            var user = User()
            user.userID = userID
            user.name = "Name"
            user.email = "\(id)@example.invalid"
            var member = GChatBridgeCore.Member()
            member.user = user
            return member
        }
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    private static func connected(people: HTTPResponse) async throws
        -> (LocalBridgeBackend, MentionTransport) {
        let transport = try MentionTransport(shell: shell(), created: created(), people: people)
        let backend = LocalBridgeBackend(cookies: cookies, transport: transport)
        try await backend.connect()
        return (backend, transport)
    }

    private static func send(_ backend: LocalBridgeBackend) async throws {
        try await backend.send(.sendMessage(
            conversationID: Conversation.ID("space/s-1"), threadID: nil, text: "@Name hi", localID: "l-1",
            mentions: [mention]
        ))
    }

    private static func sentTopic(_ transport: MentionTransport) async throws -> CreateTopicRequest {
        let request = try #require(await transport.sent.last { $0.url.path.contains("/api/create_topic") })
        return try CreateTopicRequest(serializedBytes: #require(request.body))
    }

    private static func lookups(_ transport: MentionTransport) async -> Int {
        await transport.sent.filter { $0.url.path.contains("/api/get_members") }.count
    }

    @Test func aKnownEmailIsSentWithoutALookup() async throws {
        let (backend, transport) = try await Self.connected(people: Self.people([]))
        await backend.remember(emailsOf: [
            ChatKit.Member(id: ChatKit.Member.ID("u-1"), kind: .human, email: "u-1@example.invalid")
        ])
        let before = await Self.lookups(transport)
        try await Self.send(backend)
        let annotations = try await Self.sentTopic(transport).annotations
        #expect(annotations.count == 1)
        #expect(annotations.first?.userMentionMetadata.inviteeInfo.email == "u-1@example.invalid")
        #expect(await Self.lookups(transport) == before)
    }

    @Test func anUnknownEmailIsLookedUpThenSent() async throws {
        let (backend, transport) = try await Self.connected(people: Self.people(["u-1"]))
        try await Self.send(backend)
        let annotations = try await Self.sentTopic(transport).annotations
        #expect(annotations.first?.userMentionMetadata.inviteeInfo.email == "u-1@example.invalid")
    }

    /// A lookup that fails still sends: the mention without `invitee_info` (spec §4).
    @Test func aFailedLookupStillSendsTheMention() async throws {
        let (backend, transport) = try await Self.connected(
            people: HTTPResponse(status: 500, headers: HTTPHeaders([]), body: Data())
        )
        try await Self.send(backend)
        let annotations = try await Self.sentTopic(transport).annotations
        #expect(annotations.count == 1)
        #expect(annotations.first?.userMentionMetadata.hasInviteeInfo == false)
        #expect(annotations.first?.userMentionMetadata.id.id == "u-1")
    }

    @Test func allIsSentAsMentionAll() async throws {
        let (backend, transport) = try await Self.connected(people: Self.people([]))
        try await backend.send(.sendMessage(
            conversationID: Conversation.ID("space/s-1"), threadID: nil, text: "@all hi", localID: "l-2",
            mentions: [Mention(target: .all, start: 0, length: 4)]
        ))
        let annotations = try await Self.sentTopic(transport).annotations
        #expect(annotations.first?.userMentionMetadata.type == .mentionAll)
    }

    @Test func theBridgeAdvertisesMentions() throws {
        let transport = try MentionTransport(
            shell: Self.shell(),
            created: Self.created(),
            people: Self.people([])
        )
        #expect(LocalBridgeBackend(cookies: Self.cookies, transport: transport).capabilities.canMention)
    }
}
