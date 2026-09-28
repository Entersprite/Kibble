import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

// Shared by `SenderResolutionTests` and `SenderResolutionSessionTests`,
// which were one file until it crossed `swiftlint`'s `file_length`.

actor SenderRoutingTransport: HTTPTransport {
    struct NoStream: Error {}
    struct Boom: Error {}

    private let shell, world, topics: HTTPResponse
    private let names: [String: String]
    private var failuresLeft: Int
    private var liveChunk: String?
    private var held: [CheckedContinuation<Void, Never>] = []
    private var lookupsToHold: Int
    private let selfID: String?
    private let terminalStream: Bool
    private var streamGate: CheckedContinuation<Void, Never>?
    private var streamOpened = false

    /// The member ids of every `get_members` call, in the order they were sent.
    private(set) var lookups: [Set<String>] = []

    init(
        shell: HTTPResponse,
        world: HTTPResponse,
        topics: HTTPResponse,
        names: [String: String],
        failingLookups: Int = 0,
        liveChunk: String? = nil,
        heldLookups: Int = 0,
        selfID: String? = nil,
        terminalStream: Bool = false
    ) {
        self.shell = shell
        self.world = world
        self.topics = topics
        self.names = names
        failuresLeft = failingLookups
        self.liveChunk = liveChunk
        lookupsToHold = heldLookups
        self.selfID = selfID
        self.terminalStream = terminalStream
    }

    /// Lets a held terminal stream answer its 403.
    func openStream() {
        streamOpened = true
        streamGate?.resume()
        streamGate = nil
    }

    func release() {
        for continuation in held {
            continuation.resume()
        }
        held = []
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.url.path
        if path.contains("/mole/world") {
            return shell
        }
        if path.contains("/api/get_members") {
            return try await answerLookup(request)
        }
        if path.contains("/api/list_topics") {
            return topics
        }
        if path.contains("/api/paginated_world") {
            return world
        }
        if path.contains("/api/get_self_user_status"), let selfID {
            var response = GetSelfUserStatusResponse()
            response.userStatus.userID.id = selfID
            return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    private func answerLookup(_ request: HTTPRequest) async throws -> HTTPResponse {
        let asked = try GetMembersRequest(serializedBytes: request.body ?? Data())
        let ids = asked.memberIds.map(\.userID.id)
        lookups.append(Set(ids))
        if lookupsToHold > 0 {
            lookupsToHold -= 1
            await withCheckedContinuation { held.append($0) }
        }
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw Boom()
        }
        var response = GetMembersResponse()
        response.members = ids.compactMap { id in
            guard let name = names[id] else { return nil }
            var userID = UserId()
            userID.id = id
            var user = User()
            user.userID = userID
            user.name = name
            var member = GChatBridgeCore.Member()
            member.user = user
            return member
        }
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        if terminalStream {
            // Held until `openStream()`, so a test can start a lookup while
            // the channel is still alive. 403 is terminal, not retried.
            if !streamOpened {
                await withCheckedContinuation { streamGate = $0 }
            }
            let empty = AsyncThrowingStream<Data, any Error> { $0.finish() }
            return HTTPStream(status: 403, headers: HTTPHeaders([]), body: empty)
        }
        guard let chunk = liveChunk else { throw NoStream() }
        liveChunk = nil
        return HTTPStream(
            status: 200,
            headers: HTTPHeaders([("X-HTTP-Initial-Response", #"[[0,["c","S3ss10n","",8,12,30000]]]"#)]),
            body: AsyncThrowingStream { continuation in
                continuation.yield(Data(chunk.utf8))
                continuation.finish()
            }
        )
    }
}

/// Every event the backend emits, from one iterator for the whole test.
///
/// Not a collector per step: cancelling a task suspended in
/// `AsyncStream.Iterator.next()` finishes the stream for good (`CLAUDE.md`,
/// Testing), so a second collector on the same backend would see nothing.
actor SenderEventLog {
    private(set) var events: [ChatEvent] = []
    private var pump: Task<Void, Never>?

    init(_ backend: LocalBridgeBackend) {
        pump = nil
        Task { await self.start(backend) }
    }

    private func start(_ backend: LocalBridgeBackend) {
        pump = Task {
            for await event in backend.events {
                self.append(event)
            }
        }
    }

    private func append(_ event: ChatEvent) {
        events.append(event)
    }

    /// The events since `mark`, after giving started lookups time to land.
    func settle(since mark: Int = 0) async -> [ChatEvent] {
        try? await Task.sleep(for: .milliseconds(300))
        return Array(events.dropFirst(mark))
    }
}

/// Fixtures both suites build from.
protocol SenderResolutionFixtures {}

extension SenderResolutionFixtures {
    static var cookies: SessionCookies {
        SessionCookies(header: "SID=a; COMPASS=b; OSID=c")!
    }

    static var space: Conversation.ID {
        Conversation.ID("space/s-1")
    }

    static var names: [String: String] {
        ["u-1": "Ada Lovelace", "u-2": "Grace Hopper"]
    }

    func shell() -> HTTPResponse {
        let html = LocalBridgeBackendTests.shell(app: "DynamiteWebUi")
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(html.utf8))
    }

    func spaceGroupID() -> GroupId {
        var group = GroupId()
        var space = SpaceId()
        space.spaceID = "s-1"
        group.spaceID = space
        return group
    }

    func reply(_ id: String, from sender: String) -> GChatBridgeCore.Message {
        var topic = TopicId()
        topic.groupID = spaceGroupID()
        topic.topicID = "t-\(id)"
        var parent = MessageParentId()
        parent.topicID = topic
        var messageID = MessageId()
        messageID.parentID = parent
        messageID.messageID = id
        var userID = UserId()
        userID.id = sender
        var creator = User()
        creator.userID = userID

        var message = GChatBridgeCore.Message()
        message.id = messageID
        message.creator = creator
        message.textBody = "hello"
        message.createTime = 1_700_000_000_000_000
        return message
    }

    func topics(from senders: [String]) throws -> HTTPResponse {
        var response = ListTopicsResponse()
        response.topics = senders.enumerated().map { index, sender in
            var topic = Topic()
            topic.replies = [reply("m-\(index)", from: sender)]
            return topic
        }
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    /// A world holding one DM whose members are `memberIDs`.
    func world(dmMembers memberIDs: [String] = []) throws -> HTTPResponse {
        var response = PaginatedWorldResponse()
        if !memberIDs.isEmpty {
            var item = WorldItemLite()
            var group = GroupId()
            var dm = DmId()
            dm.dmID = "d-1"
            group.dmID = dm
            item.groupID = group
            var members = WorldItemLite.DmMembers()
            members.members = memberIDs.map { id in
                var userID = UserId()
                userID.id = id
                return userID
            }
            item.dmMembers = members
            response.worldItems = [item]
        }
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    /// A `MESSAGE_POSTED` chunk from `sender`, shaped as `LiveChannelTests` does.
    func liveChunk(from sender: String) -> String {
        let group = #"[null,null,["dm-1"]]"#
        let topic = #"[null,"t-1",\#(group)]"#
        let parent = "[null,null,null,\(topic)]"
        let identifier = #"[\#(parent),"m-1"]"#
        let padding = Array(repeating: "null", count: 6).joined(separator: ",")
        let message = #"[\#(identifier),[["\#(sender)"]],"1700000000000000",\#(padding),"hi"]"#
        let body = "[null,null,null,null,null,[\(message)],null,null,null,null,null,6]"
        let event = "[null,null,null,null,null,null,null,[\(body)]]"
        let payload = #"[[\#(event),"wrapper"]]"#
        let array = "[[1,\(payload)]]"
        return "\(array.utf16.count)\n\(array)"
    }

    /// Until `transport` has seen `count` lookups. Bounded: `.timeLimit`
    /// cannot interrupt a loop that never suspends on anything cancellable.
    func awaitLookups(_ count: Int, on transport: SenderRoutingTransport) async throws {
        for _ in 0 ..< 200 where await transport.lookups.count < count {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await transport.lookups.count >= count)
    }

    func lookupErrors(in events: [ChatEvent]) -> Int {
        events.count {
            if case let .backendError(error) = $0 {
                return "\(error)".contains("get_members")
            }
            return false
        }
    }

    func resolvedNames(in events: [ChatEvent]) -> Set<String> {
        Set(events.flatMap { event -> [String] in
            guard case let .membersResolved(members) = event else { return [] }
            return members.compactMap(\.displayName)
        })
    }
}
