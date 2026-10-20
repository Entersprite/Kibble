import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@Suite(.timeLimit(.minutes(1)))
struct DirectMembershipTests {
    private let dm = Conversation.ID("dm/direct")
    private let peer = ChatKit.Member.ID("peer")

    @Test func freshWorldMembershipChangesWithoutTrustingTheCachedDirectory() async throws {
        let (backend, transport) = try await connected()
        let port: any ChatBackend = backend
        #expect(try await port.membership(of: peer, in: dm) == .member)
        try await transport.answer(world(members: ["self", "different"]))
        #expect(try await port.membership(of: peer, in: dm) == .notMember)
        try await transport.answer(world(members: ["self", "peer"]))
        #expect(try await port.membership(of: peer, in: dm) == .member)
        let paths = await transport.paths
        #expect(paths.filter { $0.contains("/api/paginated_world") }.count == 3)
        #expect(!paths.contains { $0.contains("/api/get_membership") })
        #expect(!paths.contains { $0.contains("/api/get_members") })
        await backend.disconnect()
    }

    @Test func anotherConversationAndMissingMembershipRemainUnknown() async throws {
        let (backend, transport) = try await connected()
        try await transport.answer(world(id: "different", members: ["self", "peer"]))
        #expect(try await backend.membership(of: peer, in: dm) == .unknown)
        try await transport.answer(world(members: []))
        #expect(try await backend.membership(of: peer, in: dm) == .unknown)
        await backend.disconnect()
    }

    @Test func providerFailureCannotAuthorizeAnInvitation() async throws {
        let (backend, transport) = try await connected()
        await transport.answer(HTTPResponse(status: 503, headers: HTTPHeaders([]), body: Data()))
        await #expect(throws: (any Error).self) { try await backend.membership(of: peer, in: dm) }
        await backend.disconnect()
    }

    @Test func aChangedGroupOrAppCannotAuthorizeADirectCall() async throws {
        let (backend, transport) = try await connected()
        try await transport.answer(world(members: ["self", "peer", "third"]))
        #expect(try await backend.membership(of: peer, in: dm) == .unknown)
        try await transport.answer(world(members: ["self", "peer"], app: true))
        #expect(try await backend.membership(of: peer, in: dm) == .unknown)
        await backend.disconnect()
    }

    @Test(arguments: [false, true])
    func aLateWorldCannotAuthorizeAfterDisconnectOrCancellation(cancel: Bool) async throws {
        let (backend, transport) = try await connected()
        await transport.hold()
        let query = Task { try await backend.membership(of: peer, in: dm) }
        do {
            try await transport.waitUntilHeld()
            if cancel {
                query.cancel()
            } else {
                await backend.disconnect()
            }
            await transport.release()
            await #expect(throws: CancellationError.self) { try await query.value }
        } catch {
            await transport.release()
            _ = await query.result
            await backend.disconnect()
            throw error
        }
        await backend.disconnect()
    }

    private func connected() async throws -> (LocalBridgeBackend, DirectMembershipTransport) {
        let transport = try DirectMembershipTransport(world: world(members: ["self", "peer"]))
        let backend = LocalBridgeBackend(
            cookies: SessionCookies(header: "SID=fixture; COMPASS=fixture; OSID=fixture")!,
            transport: transport
        )
        try await backend.connect()
        return (backend, transport)
    }

    private func world(id: String = "direct", members: [String], app: Bool = false) throws -> HTTPResponse {
        var item = WorldItemLite()
        item.groupID.dmID.dmID = id
        if app {
            item.attributeCheckerGroupType = .oneToOneBotDm
        }
        item.dmMembers.members = members.map { id in var user = UserId(); user.id = id; return user }
        var response = PaginatedWorldResponse()
        response.worldItems = [item]
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }
}

private actor DirectMembershipTransport: HTTPTransport {
    private var world: HTTPResponse
    private var holds = false
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var paths: [String] = []

    init(world: HTTPResponse) {
        self.world = world
    }

    func answer(_ world: HTTPResponse) {
        self.world = world
    }

    func hold() {
        holds = true
    }

    func release() {
        pending?.resume(); pending = nil
    }

    func waitUntilHeld() async throws {
        for _ in 0 ..< 1000 {
            if pending != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(pending != nil)
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        paths.append(request.url.path)
        if request.url.path.contains("/mole/world") {
            return HTTPResponse(
                status: 200, headers: HTTPHeaders([]),
                body: Data(LocalBridgeBackendTests.shell(app: "DynamiteWebUi").utf8)
            )
        }
        if request.url.path.contains("/api/paginated_world") {
            if holds {
                await withCheckedContinuation { pending = $0 }
            }
            return world
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw URLError(.notConnectedToInternet)
    }
}
