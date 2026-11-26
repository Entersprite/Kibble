import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@Suite(.timeLimit(.minutes(1)))
struct BlockedConversationsBackendTests {
    @Test func listsTheRoomAndUsesTheOriginalAddressForOneUnblock() async throws {
        let transport = BlockedRoomTransport()
        let backend = try await connect(transport)
        let room = Conversation.ID("space/fixture")
        #expect(try await backend.blockedConversations() == [.init(id: room, name: "Fixture Room")])
        #expect(try await backend.unblockConversation(.init("space/other")).map(\.id) == [room])
        #expect(try await backend.unblockConversation(room).isEmpty)
        #expect(try await backend.unblockConversation(room).isEmpty)
        #expect(await transport.rpcs == ["abmOGd", "abmOGd", "abmOGd", "BFhA9d", "abmOGd", "abmOGd"])
        await backend.disconnect()
    }

    @Test func aSparseUnblockReplyNeedsAConfirmedListChange() async throws {
        let transport = BlockedRoomTransport(acceptsUnblock: false)
        let backend = try await connect(transport)
        let room = Conversation.ID("space/fixture")
        await #expect(throws: ChatError.self) { _ = try await backend.unblockConversation(room) }
        #expect(await transport.rpcs == ["abmOGd", "BFhA9d", "abmOGd"])
        #expect(try await backend.blockedConversations().map(\.id) == [room])
        await backend.disconnect()
    }

    private func connect(_ transport: BlockedRoomTransport) async throws -> LocalBridgeBackend {
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        return backend
    }
}

private actor BlockedRoomTransport: HTTPTransport {
    let base = ActionTransport(kind: .space)
    let acceptsUnblock: Bool
    private(set) var rpcs: [String] = []
    private var blocked = true

    init(acceptsUnblock: Bool = true) {
        self.acceptsUnblock = acceptsUnblock
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let endpoint = request.url.lastPathComponent
        if request.url.path.hasSuffix("/app") || request.url.path.hasSuffix("/app/home") {
            return SearchFixtures.fullShell()
        }
        if endpoint != "batchexecute" {
            return try await base.send(request)
        }
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems
        let rpc = try #require(query?.first(where: { $0.name == "rpcids" })?.value)
        #expect(query?.first(where: { $0.name == "source-path" })?.value == "/app/home")
        let input = try SearchFixtures.innerPayload(of: request)
        rpcs.append(rpc)
        if rpc == "abmOGd" {
            #expect(input.isEmpty && request.method == .post)
            let row: [Any] = [["space/fixture", "fixture", 2], "Fixture Room"]
            let inner: [Any] = blocked ? [[row]] : []
            return try SearchFixtures.ok(SearchFixtures.answerBody(inner: inner, rpc: rpc)).get()
        }
        #expect(rpc == "BFhA9d" && request.method == .post)
        let payload = try JSONSerialization.data(withJSONObject: input)
        let decoded = try PBLiteDecoder.decode(UnblockRoomRequest.self, fromJSON: payload)
        #expect(decoded.issues.isEmpty)
        #expect(decoded.message.group.id == "space/fixture")
        #expect(decoded.message.group.rawID == "fixture" && decoded.message.group.kind == 2)
        #expect(decoded.message.hasBlocked && !decoded.message.blocked)
        #expect(decoded.message.hasReported && !decoded.message.reported)
        blocked = !acceptsUnblock
        return try SearchFixtures.ok(SearchFixtures.answerBody(inner: [], rpc: rpc)).get()
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }
}
