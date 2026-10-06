import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Answers the shell for `connect()`, then `list_members` page by page and
/// `get_members` with one fixed answer. Duplicated rather than shared, the
/// call `SendMessageTests`' own `RoutingTransport` makes.
private actor MembersTransport: HTTPTransport {
    struct NoStream: Error {}

    private let shell: HTTPResponse
    private var listPages: [HTTPResponse]
    private let getMembers: HTTPResponse
    private(set) var sent: [HTTPRequest] = []

    init(shell: HTTPResponse, listPages: [HTTPResponse], getMembers: HTTPResponse) {
        self.shell = shell
        self.listPages = listPages
        self.getMembers = getMembers
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        if request.url.path.contains("/mole/world") {
            return shell
        }
        if request.url.path.contains("/api/list_members") {
            guard !listPages.isEmpty else {
                return HTTPResponse(status: 500, headers: HTTPHeaders([]), body: Data())
            }
            return listPages.removeFirst()
        }
        if request.url.path.contains("/api/get_members") {
            return getMembers
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }
}

/// `.loadMembers`: `list_members` for a space, then one `get_members` for
/// names and emails, then `.membersChanged` (mention composer spec §3.2).
@Suite(.timeLimit(.minutes(1)))
struct LoadMembersTests {
    private static let cookies = SessionCookies(header: "SID=a; COMPASS=b; OSID=c")!
    private static let space = Conversation.ID("space/s-1")

    private static func shell() -> HTTPResponse {
        let html = LocalBridgeBackendTests.shell(app: "DynamiteWebUi")
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(html.utf8))
    }

    private static func membership(_ id: String, state: MembershipState = .memberJoined) -> Membership {
        var user = UserId()
        user.id = id
        var member = MemberId()
        member.userID = user
        var membershipID = MembershipId()
        membershipID.memberID = member
        var membership = Membership()
        membership.id = membershipID
        membership.membershipState = state
        return membership
    }

    private static func page(
        _ ids: [String],
        invited: [String] = [],
        next: String = ""
    ) throws -> HTTPResponse {
        var response = ListMembersResponse()
        response.memberships = ids.map { membership($0) } + invited
            .map { membership($0, state: .memberInvited) }
        response.nextPageToken = next
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    private static func people(_ ids: [String]) throws -> HTTPResponse {
        var response = GetMembersResponse()
        response.members = ids.map { id in
            var userID = UserId()
            userID.id = id
            var user = User()
            user.userID = userID
            user.name = "Name \(id)"
            user.email = "\(id)@example.invalid"
            var member = GChatBridgeCore.Member()
            member.user = user
            return member
        }
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    private static func connected(_ transport: MembersTransport) async throws -> LocalBridgeBackend {
        let backend = LocalBridgeBackend(cookies: cookies, transport: transport)
        try await backend.connect()
        return backend
    }

    private static func membersChanged(_ backend: LocalBridgeBackend) async -> [ChatKit.Member]? {
        var iterator = backend.events.makeAsyncIterator()
        for _ in 0 ..< 100 {
            guard let event = await iterator.next() else { return nil }
            if case let .membersChanged(conversation, members) = event, conversation == space {
                return members
            }
        }
        return nil
    }

    private static func listCalls(_ transport: MembersTransport) async -> [HTTPRequest] {
        await transport.sent.filter { $0.url.path.contains("/api/list_members") }
    }

    @Test func aSpacesJoinedMembersArriveNamedInListOrder() async throws {
        let transport = try MembersTransport(
            shell: Self.shell(),
            listPages: [Self.page(["u-2", "u-1"], invited: ["u-9"])],
            // The invitee is a real person `get_members` would name, so only
            // the joined-state guard can keep them out.
            getMembers: Self.people(["u-1", "u-2", "u-9"])
        )
        let backend = try await Self.connected(transport)
        async let changed = Self.membersChanged(backend)
        try await backend.send(.loadMembers(conversationID: Self.space))
        let members = try #require(await changed)
        #expect(members.map(\.id.rawValue) == ["u-2", "u-1"])
        #expect(members.first?.email == "u-2@example.invalid")
        #expect(await backend.memberEmails[ChatKit.Member.ID("u-1")] == "u-1@example.invalid")
    }

    @Test func pagesAreFollowed() async throws {
        let transport = try MembersTransport(
            shell: Self.shell(),
            listPages: [Self.page(["u-1"], next: "p2"), Self.page(["u-2"])],
            getMembers: Self.people(["u-1", "u-2"])
        )
        let backend = try await Self.connected(transport)
        async let changed = Self.membersChanged(backend)
        try await backend.send(.loadMembers(conversationID: Self.space))
        #expect(try #require(await changed).map(\.id.rawValue) == ["u-1", "u-2"])
        let sent = await Self.listCalls(transport)
        #expect(sent.count == 2)
        let second = try ListMembersRequest(serializedBytes: #require(sent.last?.body))
        #expect(second.pageToken == "p2")
    }

    @Test func pagingStopsAtTheLimit() async throws {
        let pages = try (0 ..< 12).map { try Self.page(["u-\($0)"], next: "p\($0 + 1)") }
        let transport = try MembersTransport(
            shell: Self.shell(), listPages: pages, getMembers: Self.people((0 ..< 10).map { "u-\($0)" })
        )
        let backend = try await Self.connected(transport)
        try await backend.send(.loadMembers(conversationID: Self.space))
        #expect(await Self.listCalls(transport).count == LocalBridgeBackend.memberPageLimit)
    }

    /// Review finding 4: `SyncReducer.supersedingStaleError` clears the last
    /// error on `.membersChanged`, so an error emitted before it was never
    /// shown (CLAUDE.md, session 34). The clean-up first, the error last.
    @Test func theCutListErrorComesAfterTheMembers() async throws {
        let pages = try (0 ..< 12).map { try Self.page(["u-\($0)"], next: "p\($0 + 1)") }
        let transport = try MembersTransport(
            shell: Self.shell(), listPages: pages, getMembers: Self.people((0 ..< 10).map { "u-\($0)" })
        )
        let backend = try await Self.connected(transport)
        try await backend.send(.loadMembers(conversationID: Self.space))
        var iterator = backend.events.makeAsyncIterator()
        var order: [String] = []
        for _ in 0 ..< 100 {
            guard let event = await iterator.next() else { break }
            switch event {
            case let .membersChanged(conversation, _) where conversation == Self.space:
                order.append("members")
            case let .backendError(error) where String(describing: error).contains("list_members answered"):
                order.append("error")
            default:
                break
            }
            if order.count == 2 {
                break
            }
        }
        #expect(order == ["members", "error"])
    }

    @Test func aDirectMessageAsksNothing() async throws {
        let transport = try MembersTransport(shell: Self.shell(), listPages: [], getMembers: Self.people([]))
        let backend = try await Self.connected(transport)
        try await backend.send(.loadMembers(conversationID: Conversation.ID("dm/d-1")))
        #expect(await Self.listCalls(transport).isEmpty)
    }

    /// A failure throws, so `SyncEngine.submit` records it and the next
    /// selection retries (spec §4).
    @Test func aFailedListThrows() async throws {
        let transport = try MembersTransport(shell: Self.shell(), listPages: [], getMembers: Self.people([]))
        let backend = try await Self.connected(transport)
        await #expect(throws: (any Error).self) {
            try await backend.send(.loadMembers(conversationID: Self.space))
        }
    }
}
