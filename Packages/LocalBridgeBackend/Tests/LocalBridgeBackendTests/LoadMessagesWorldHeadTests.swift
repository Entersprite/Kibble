import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// A world item can report a newer head than the plain history page contains.
/// Queueing by method keeps the channel's background calls from consuming a
/// history response intended for this test.
private actor WorldHeadTransport: HTTPTransport {
    struct NoStream: Error {}
    struct Exhausted: Error {}

    let world: HTTPResponse
    var topics: [HTTPResponse]
    private(set) var topicRequests: [HTTPRequest] = []

    init(world: HTTPResponse, topics: [HTTPResponse]) {
        self.world = world
        self.topics = topics
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.url.path
        if path.contains("/mole/world") {
            let html = LocalBridgeBackendTests.shell(app: "DynamiteWebUi")
            return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(html.utf8))
        }
        if path.contains("/api/paginated_world") {
            return world
        }
        if path.contains("/api/list_topics") {
            topicRequests.append(request)
            guard !topics.isEmpty else { throw Exhausted() }
            return topics.removeFirst()
        }
        if path.contains("/api/get_members") {
            return try HTTPResponse(
                status: 200, headers: HTTPHeaders([]), body: GetMembersResponse().serializedBytes()
            )
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct LoadMessagesWorldHeadTests {
    private static let space = Conversation.ID("space/s-1")
    private static let oldTime: Int64 = 1_790_000_000_000_000
    private static let headTime: Int64 = 1_790_000_000_001_000

    private static func group() -> GroupId {
        var group = GroupId()
        group.spaceID.spaceID = "s-1"
        return group
    }

    private static func worldResponse() throws -> HTTPResponse {
        var item = WorldItemLite()
        item.groupID = group()
        item.roomName = "Example"
        item.readState.lastReadTime = oldTime + 500
        item.readState.lastHeadMessageCreateTimeUsec = headTime
        var world = PaginatedWorldResponse()
        world.worldItems = [item]
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: world.serializedBytes())
    }

    private static func message(_ id: String, at time: Int64) -> GChatBridgeCore.Message {
        var message = GChatBridgeCore.Message()
        message.id.messageID = id
        message.id.parentID.topicID.topicID = id
        message.id.parentID.topicID.groupID = group()
        message.creator.userID.id = "u-1"
        message.createTime = time
        return message
    }

    private static func topicsResponse(_ messages: [GChatBridgeCore.Message]) throws -> HTTPResponse {
        var response = ListTopicsResponse()
        response.topics = messages.map { message in
            var topic = Topic()
            topic.id = message.id.parentID.topicID
            topic.replies = [message]
            return topic
        }
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    @Test func fetchesAnAnchoredHeadPageWhenPlainHistoryLagsTheWorld() async throws {
        let old = Self.message("m-old", at: Self.oldTime)
        let head = Self.message("m-head", at: Self.headTime)
        let transport = try WorldHeadTransport(
            world: Self.worldResponse(),
            topics: [Self.topicsResponse([old]), Self.topicsResponse([old, head])]
        )
        let backend = try LocalBridgeBackend(
            cookies: #require(SessionCookies(header: "SID=a; COMPASS=b; OSID=c")), transport: transport
        )
        try await backend.connect()
        let conversations = try await backend.loadConversations()
        #expect(conversations.first?.id == Self.space)
        #expect(conversations.first?.hasUnread == true)

        let messages = try await backend.loadMessages(in: Self.space, before: nil)
        #expect(messages.map(\.id.rawValue) == ["m-old", "m-head"])

        let requests = await transport.topicRequests
        #expect(requests.count == 2)
        let plain = try ListTopicsRequest(serializedBytes: #require(requests.first?.body))
        #expect(!plain.hasFilter)
        let anchored = try ListTopicsRequest(serializedBytes: #require(requests.last?.body))
        #expect(anchored.filter.anchor.timeUsec == Self.headTime)
        #expect(anchored.sortOption == 2)
    }
}
