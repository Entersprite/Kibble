import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Names for people the world response never listed - senders on a history
/// page and on the live channel - looked up with `get_members` on demand.
/// A named space or a Meet chat lists no members (`findings.md` §37.5).
///
/// `RoutingTransport` is duplicated rather than shared, the same call
/// `LoadMessagesTests.swift` makes for its own.
private actor RoutingTransport: HTTPTransport {
    struct NoStream: Error {}
    struct Boom: Error {}

    private let shell, world, topics: HTTPResponse
    private let names: [String: String]
    private var failuresLeft: Int
    private var liveChunk: String?
    private var held: [CheckedContinuation<Void, Never>] = []
    private let holdsLookups: Bool

    /// The member ids of every `get_members` call, in the order they were sent.
    private(set) var lookups: [Set<String>] = []

    init(
        shell: HTTPResponse,
        world: HTTPResponse,
        topics: HTTPResponse,
        names: [String: String],
        failingLookups: Int = 0,
        liveChunk: String? = nil,
        holdsLookups: Bool = false
    ) {
        self.shell = shell
        self.world = world
        self.topics = topics
        self.names = names
        failuresLeft = failingLookups
        self.liveChunk = liveChunk
        self.holdsLookups = holdsLookups
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
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    private func answerLookup(_ request: HTTPRequest) async throws -> HTTPResponse {
        let asked = try GetMembersRequest(serializedBytes: request.body ?? Data())
        let ids = asked.memberIds.map(\.userID.id)
        lookups.append(Set(ids))
        if holdsLookups {
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

@Suite(.timeLimit(.minutes(1)))
struct SenderResolutionTests {
    private static let cookies = SessionCookies(header: "SID=a; COMPASS=b; OSID=c")!
    private static let space = Conversation.ID("space/s-1")
    private static let names = ["u-1": "Ada Lovelace", "u-2": "Grace Hopper"]

    // MARK: - Fixtures

    private func shell() -> HTTPResponse {
        let html = LocalBridgeBackendTests.shell(app: "DynamiteWebUi")
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(html.utf8))
    }

    private func spaceGroupID() -> GroupId {
        var group = GroupId()
        var space = SpaceId()
        space.spaceID = "s-1"
        group.spaceID = space
        return group
    }

    private func reply(_ id: String, from sender: String) -> GChatBridgeCore.Message {
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

    private func topics(from senders: [String]) throws -> HTTPResponse {
        var response = ListTopicsResponse()
        response.topics = senders.enumerated().map { index, sender in
            var topic = Topic()
            topic.replies = [reply("m-\(index)", from: sender)]
            return topic
        }
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    /// A world holding one DM whose members are `memberIDs`.
    private func world(dmMembers memberIDs: [String] = []) throws -> HTTPResponse {
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
    private func liveChunk(from sender: String) -> String {
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

    /// Every event the backend emits, from one iterator for the whole test.
    ///
    /// Not a collector per step: cancelling a task suspended in
    /// `AsyncStream.Iterator.next()` finishes the stream for good (`CLAUDE.md`,
    /// Testing), so a second collector on the same backend would see nothing.
    private actor EventLog {
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

    private func resolvedNames(in events: [ChatEvent]) -> Set<String> {
        Set(events.flatMap { event -> [String] in
            guard case let .membersResolved(members) = event else { return [] }
            return members.compactMap(\.displayName)
        })
    }

    // MARK: - History

    /// The discriminating test: a space's history page names senders nothing
    /// else ever listed. Deleting the lookup in `loadMessages(in:before:)`
    /// turns this red.
    @Test func aHistoryPageLooksUpItsSendersNames() async throws {
        let transport = try RoutingTransport(
            shell: shell(), world: world(), topics: topics(from: ["u-1", "u-2", "u-1"]), names: Self.names
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        let log = EventLog(backend)
        try await backend.connect()

        let messages = try await backend.loadMessages(in: Self.space, before: nil)
        let events = await log.settle()

        #expect(messages.count == 3)
        #expect(resolvedNames(in: events) == ["Ada Lovelace", "Grace Hopper"])
        #expect(await transport.lookups == [["u-1", "u-2"]])
        await backend.disconnect()
    }

    /// The second page of the same senders asks nothing.
    @Test func aSenderAlreadyAskedAboutIsNotAskedAgain() async throws {
        let transport = try RoutingTransport(
            shell: shell(), world: world(), topics: topics(from: ["u-1"]), names: Self.names
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        let log = EventLog(backend)
        try await backend.connect()

        _ = try await backend.loadMessages(in: Self.space, before: nil)
        _ = await log.settle()
        _ = try await backend.loadMessages(in: Self.space, before: nil)
        _ = await log.settle()

        #expect(await transport.lookups == [["u-1"]])
        await backend.disconnect()
    }

    /// Members the world load already asked about are not asked again.
    @Test func theWorldLoadsMembersAreNotAskedAgain() async throws {
        let transport = try RoutingTransport(
            shell: shell(),
            world: world(dmMembers: ["u-1"]),
            topics: topics(from: ["u-1", "u-2"]),
            names: Self.names
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        let log = EventLog(backend)
        try await backend.connect()

        _ = try await backend.loadConversations()
        _ = await log.settle()
        _ = try await backend.loadMessages(in: Self.space, before: nil)
        _ = await log.settle()

        #expect(await transport.lookups == [["u-1"], ["u-2"]])
        await backend.disconnect()
    }

    /// A failed lookup is reported, and forgotten, so the next page asks
    /// again rather than leaving those people unnamed for the whole session.
    @Test func aFailedLookupIsReportedAndRetriedByTheNextPage() async throws {
        let transport = try RoutingTransport(
            shell: shell(), world: world(), topics: topics(from: ["u-1"]), names: Self.names,
            failingLookups: 1
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        let log = EventLog(backend)
        try await backend.connect()

        _ = try await backend.loadMessages(in: Self.space, before: nil)
        let first = await log.settle()
        _ = try await backend.loadMessages(in: Self.space, before: nil)
        let second = await log.settle(since: first.count)

        #expect(first.contains {
            if case let .backendError(error) = $0 {
                return "\(error)".contains("get_members")
            }
            return false
        })
        #expect(resolvedNames(in: first).isEmpty)
        #expect(resolvedNames(in: second) == ["Ada Lovelace"])
        #expect(await transport.lookups == [["u-1"], ["u-1"]])
        await backend.disconnect()
    }

    /// A lookup that answers after `disconnect()` belongs to a session that
    /// has gone, and must not land in the next one. Deleting the generation
    /// check in the lookup turns this red.
    @Test func aLookupThatLandsAfterDisconnectEmitsNothing() async throws {
        let transport = try RoutingTransport(
            shell: shell(), world: world(), topics: topics(from: ["u-1"]), names: Self.names,
            holdsLookups: true
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        let log = EventLog(backend)
        try await backend.connect()
        _ = try await backend.loadMessages(in: Self.space, before: nil)
        // Positive control: the lookup really is in flight before the
        // disconnect, so "nothing emitted" below is not "nothing asked".
        // Bounded: `.timeLimit` cannot interrupt a loop that never suspends
        // on anything cancellable, so an unbounded one hangs the suite.
        for _ in 0 ..< 200 where await transport.lookups.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await !transport.lookups.isEmpty)

        await backend.disconnect()
        await transport.release()
        let events = await log.settle()

        #expect(resolvedNames(in: events).isEmpty)
    }

    // MARK: - Live

    /// A typing indicator draws a name too, so a typer is looked up like a sender.
    @Test func sendersAndTypersAreTheIdsAChannelEventNames() {
        let message = ChatKit.Message(
            id: ChatKit.Message.ID("m-1"),
            conversationID: Self.space,
            threadID: MessageThread.ID("t-1"),
            sender: ChatKit.Member.ID("u-1"),
            text: "hi",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let typer = ChatKit.Member.ID("u-2")
        #expect(LocalBridgeBackend.memberIDs(in: .messageReceived(message)) == [message.sender])
        #expect(LocalBridgeBackend.memberIDs(in: .messageUpdated(message)) == [message.sender])
        #expect(LocalBridgeBackend.memberIDs(
            in: .typingChanged(conversationID: Self.space, member: typer, isTyping: true)
        ) == [typer])
        #expect(LocalBridgeBackend.memberIDs(in: .messageDeleted(id: message.id, in: Self.space)).isEmpty)
    }

    /// A message on the channel from someone never seen before names them.
    @Test func aLiveMessageFromAStrangerLooksUpTheirName() async throws {
        let transport = try RoutingTransport(
            shell: shell(), world: world(), topics: topics(from: []), names: Self.names,
            liveChunk: liveChunk(from: "u-2")
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        let log = EventLog(backend)
        try await backend.connect()

        let events = await log.settle()

        #expect(events.contains {
            if case .messageReceived = $0 {
                return true
            }
            return false
        })
        #expect(resolvedNames(in: events) == ["Grace Hopper"])
        #expect(await transport.lookups == [["u-2"]])
        await backend.disconnect()
    }
}
