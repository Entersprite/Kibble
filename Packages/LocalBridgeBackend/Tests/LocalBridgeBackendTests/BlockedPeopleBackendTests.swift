import ChatKit
import Foundation
import GChatBridgeCore
import SwiftProtobuf
import Testing
@testable import LocalBridgeBackend

@Suite(.timeLimit(.minutes(1)))
struct BlockedPeopleBackendTests {
    @Test func unblockUsesTheListedUserAndConfirmsRemovalAfterAReplyIsLost() async throws {
        let transport = BlockedPeopleTransport(appliesUnblock: true)
        let backend = try await connect(transport)
        let id = ChatKit.Member.ID("blocked-user")
        let expected = [BlockedPerson(id: id, name: "Blocked User")]
        #expect(try await backend.blockedPeople() == expected)
        #expect(try await backend.unblockPerson(.init("unlisted")).map(\.id) == [id])
        #expect(try await backend.unblockPerson(id).isEmpty)
        #expect(try await backend.unblockPerson(id).isEmpty)
        #expect(await transport.writes == [id.rawValue])
        await backend.disconnect()
    }

    @Test func aSuccessfulHttpResponseCannotConfirmAnUnchangedList() async throws {
        let transport = BlockedPeopleTransport(appliesUnblock: false)
        let backend = try await connect(transport)
        let id = ChatKit.Member.ID("blocked-user")
        await #expect(throws: ChatError.self) { try await backend.unblockPerson(id) }
        #expect(try await backend.blockedPeople().map(\.id) == [id])
        #expect(await transport.writes == [id.rawValue])
        await backend.disconnect()
    }

    private func connect(_ transport: BlockedPeopleTransport) async throws -> LocalBridgeBackend {
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        return backend
    }
}

private actor BlockedPeopleTransport: HTTPTransport {
    let base = ActionTransport(kind: .space)
    let appliesUnblock: Bool
    private var blocked = true
    private(set) var writes: [String] = []

    init(appliesUnblock: Bool) {
        self.appliesUnblock = appliesUnblock
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch request.url.lastPathComponent {
        case "list_blocked_users":
            let input = try ListBlockedUsersRequest(serializedBytes: request.body ?? Data())
            #expect(input.hasRequestHeader && request.method == .post)
            var row = UserId()
            row.id = "blocked-user"
            row.type = .human
            var reply = ListBlockedUsersResponse()
            reply.blockedUserID = blocked ? [row] : []
            return try ok(reply)
        case "get_members":
            let input = try GetMembersRequest(serializedBytes: request.body ?? Data())
            if input.memberIds.map(\.userID.id) == ["blocked-user"] {
                var row = GChatBridgeCore.Member()
                row.user.userID.id = "blocked-user"
                row.user.name = "Blocked User"
                var reply = GetMembersResponse()
                reply.members = [row]
                return try ok(reply)
            }
        case "block_entity":
            let input = try BlockEntityRequest(serializedBytes: request.body ?? Data())
            #expect(input.userID.id == "blocked-user" && input.userID.hasType)
            #expect(input.groupID.id == nil && input.hasRequestHeader)
            #expect(input.hasBlocked && !input.blocked && input.hasReported && !input.reported)
            writes.append(input.userID.id)
            if appliesUnblock {
                blocked = false
                return HTTPResponse(status: 503, headers: HTTPHeaders([]), body: Data())
            }
            return try ok(BlockEntityResponse())
        default: break
        }
        return try await base.send(request)
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }

    private func ok(_ message: some SwiftProtobuf.Message) throws -> HTTPResponse {
        try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: message.serializedBytes())
    }
}
