import ChatKit
import Foundation
import GChatBridgeCore
import SwiftProtobuf
import Testing
@testable import LocalBridgeBackend

private actor ManagementTransport: HTTPTransport {
    let base = ActionTransport(kind: .space)
    var name = "Design Team"
    var grants: [Int32] = [6, 8, 54]
    private(set) var writes = 0
    private(set) var deletionRequests: [DeleteGroupV2Request] = []
    var rejectDeletion = false
    var deleted = false
    /// The people page's rows: a user id, `nil` for a member that is not a
    /// person (an app or a group), or a row naming another conversation.
    var rows: [PeopleRow] = [.user("u-1"), .user("u-2")]

    enum PeopleRow {
        case user(String), notAPerson, elsewhere(String)
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch request.url.lastPathComponent {
        case "list_members", "get_members":
            return try peopleReply(request)
        case "get_group":
            if deleted {
                return HTTPResponse(status: 403, headers: HTTPHeaders([]), body: Data())
            }
            let input = try GetGroupRequest(serializedBytes: request.body ?? Data())
            var response = GetGroupResponse()
            response.group.groupID = input.groupID
            response.group.name = name
            response.group.attributeCheckerGroupType = .flatRoom
            response.group.revisionTime = Int64(writes + 1)
            response.membershipState = .memberJoined
            return try ok(response)
        case "get_group_scoped_capabilities":
            let input = try GetGroupScopedCapabilitiesRequest(serializedBytes: request.body ?? Data())
            var caps = GroupScopedCapabilities()
            caps.id = input.membershipIds[0]; caps.capabilities = grants
            var response = GetGroupScopedCapabilitiesResponse(); response.capabilities = [caps]
            return try ok(response)
        case "update_group":
            writes += 1
            let input = try UpdateGroupRequest(serializedBytes: request.body ?? Data())
            name = input.name
            var response = UpdateGroupResponse()
            response.group.groupID = input.groupID; response.group.name = name
            return try ok(response)
        case "delete_group_v2":
            let input = try DeleteGroupV2Request(serializedBytes: request.body ?? Data())
            deletionRequests.append(input)
            if rejectDeletion {
                return HTTPResponse(status: 403, headers: HTTPHeaders([]), body: Data())
            }
            deleted = true
            return try ok(DeleteGroupV2Response())
        default: return try await base.send(request)
        }
    }

    func revoke() {
        grants = []
    }

    func setRows(_ rows: [PeopleRow]) {
        self.rows = rows
    }

    private func peopleReply(_ request: HTTPRequest) throws -> HTTPResponse {
        if request.url.lastPathComponent == "list_members" {
            let input = try ListMembersRequest(serializedBytes: request.body ?? Data())
            var response = ListMembersResponse()
            response.memberships = rows.map { Self.membership($0, in: input.groupID) }
            return try ok(response)
        }
        let input = try GetMembersRequest(serializedBytes: request.body ?? Data())
        var response = GetMembersResponse()
        response.members = input.memberIds.map { id in
            var user = User()
            user.userID = id.userID
            user.name = "Name \(id.userID.id)"
            var member = GChatBridgeCore.Member()
            member.user = user
            return member
        }
        return try ok(response)
    }

    private static func membership(_ row: PeopleRow, in group: GroupId) -> Membership {
        var id = MembershipId()
        id.groupID = group
        switch row {
        case let .user(value):
            id.memberID.userID.id = value
        case .notAPerson:
            break
        case let .elsewhere(value):
            id.memberID.userID.id = value
            id.groupID.spaceID.spaceID = "somewhere-else"
        }
        var membership = Membership()
        membership.id = id
        membership.membershipState = .memberJoined
        return membership
    }

    func allowDeletion(reject: Bool = false) {
        grants.append(2)
        rejectDeletion = reject
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }

    private func ok(_ value: some SwiftProtobuf.Message) throws -> HTTPResponse {
        try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: value.serializedData())
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ManagementBackendTests {
    @Test func aDirectMessageNeverOffersSpaceDeletionEvenWithTheLegacyGrant() async throws {
        let transport = ManagementTransport()
        await transport.allowDeletion()
        let backend = try await connected(transport)
        let id = Conversation.ID("dm/a")
        let before = try await backend.conversationDetails(id)
        #expect(!before.allowedActions.contains("deleteSpace"))
        await #expect(throws: ChatError.self) {
            _ = try await backend.mutateConversation(
                .deleteSpace,
                in: id,
                operationID: "wrong-kind",
                expectedRevision: nil
            )
        }
        #expect(await transport.deletionRequests.isEmpty)
        await backend.disconnect()
    }

    @Test func deletionAwaitsAcknowledgementAndNeverRepeatsOrReloadsTheDeletedSpace() async throws {
        let transport = ManagementTransport()
        await transport.allowDeletion()
        let backend = try await connected(transport)
        let id = Conversation.ID("space/a")
        let before = try await backend.conversationDetails(id)
        #expect(before.allowedActions.contains("deleteSpace"))
        let result = try await backend.mutateConversation(
            .deleteSpace, in: id, operationID: "delete", expectedRevision: before.revision
        )
        #expect(result.isConfirmed)
        #expect(result.details?.membership != .joined)
        #expect(result.details?.allowedActions.isEmpty == true)
        #expect(try await backend.mutateConversation(
            .deleteSpace, in: id, operationID: "delete", expectedRevision: before.revision
        ) == result)
        let requests = await transport.deletionRequests
        #expect(requests.count == 1)
        #expect(requests.first?.preserveLinkedGroup == true)
        await backend.disconnect()
    }

    @Test func refusedDeletionIsNotReportedAsConfirmedAndRevokedPermissionPreventsTheWrite() async throws {
        let transport = ManagementTransport()
        await transport.allowDeletion(reject: true)
        let backend = try await connected(transport)
        let id = Conversation.ID("space/a")
        let before = try await backend.conversationDetails(id)
        await #expect(throws: (any Error).self) {
            _ = try await backend.mutateConversation(
                .deleteSpace,
                in: id,
                operationID: "refused",
                expectedRevision: nil
            )
        }
        let replay = try await backend.mutateConversation(
            .deleteSpace, in: id, operationID: "refused", expectedRevision: nil
        )
        #expect(!replay.isConfirmed)
        await transport.revoke()
        await #expect(throws: ChatError.self) {
            _ = try await backend.mutateConversation(
                .deleteSpace, in: id, operationID: "revoked-delete", expectedRevision: before.revision
            )
        }
        #expect(await transport.deletionRequests.count == 1)
        await backend.disconnect()
    }

    private func connected(_ transport: ManagementTransport) async throws -> LocalBridgeBackend {
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        return backend
    }

    @Test func renameIsAwaitedAndReplayingAnOperationCannotRenameAgain() async throws {
        let transport = ManagementTransport()
        let backend = try await connected(transport)
        let contract: any ChatBackend = backend
        let id = Conversation.ID("space/a")
        let before = try await contract.conversationDetails(id)
        #expect(before.allowedActions.contains("identity"))
        let patch = ConversationMutation.identity(name: "Renamed", description: nil, access: nil)
        let result = try await contract.mutateConversation(
            patch,
            in: id,
            operationID: "rename-one",
            expectedRevision: before.revision
        )
        #expect(result.isConfirmed)
        #expect(result.details?.conversation.title == "Renamed")
        let replay = try await contract.mutateConversation(
            patch,
            in: id,
            operationID: "rename-one",
            expectedRevision: before.revision
        )
        #expect(replay == result)
        let count = await transport.writes
        #expect(count == 1)
        await #expect(throws: ChatError.self) {
            _ = try await contract.mutateConversation(
                .identity(name: "Different", description: nil, access: nil),
                in: id,
                operationID: "rename-one",
                expectedRevision: before.revision
            )
        }
        await backend.disconnect()
    }

    /// The service fences a query against any event that could change the
    /// media it records, and asks again when one arrives mid-query. A people
    /// page that announced its own names was therefore asked three times and
    /// reported as overloaded, every time: an empty People tab.
    /// Only membership announcements count: the fake channel's own reconnects
    /// may arrive in the same window and are not the page's doing.
    @Test func aPeoplePageAnnouncesNoMembersWhileItIsAwaited() async throws {
        let transport = ManagementTransport()
        let backend = try await connected(transport)
        let log = SenderEventLog(backend)
        let mark = await log.settle().count
        let page = try await backend.participants(in: Conversation.ID("space/a"), after: nil)
        #expect(page.participants.map(\.id.rawValue) == ["u-1", "u-2"])
        #expect(page.participants.map(\.member.displayName) == ["Name u-1", "Name u-2"])
        let announced = await log.settle(since: mark).filter {
            switch $0 {
            case .membersResolved, .membersChanged: true
            default: false
            }
        }
        #expect(announced.isEmpty, "\(announced)")
        await backend.disconnect()
    }

    @Test func aMemberWhoIsNotAPersonIsLeftOutRatherThanHidingEveryone() async throws {
        let transport = ManagementTransport()
        await transport.setRows([.user("u-1"), .notAPerson, .user("u-2")])
        let backend = try await connected(transport)
        let page = try await backend.participants(in: Conversation.ID("space/a"), after: nil)
        #expect(page.participants.map(\.id.rawValue) == ["u-1", "u-2"])
        await backend.disconnect()
    }

    @Test func aRowFromAnotherConversationStillRefusesThePage() async throws {
        let transport = ManagementTransport()
        await transport.setRows([.user("u-1"), .elsewhere("u-2")])
        let backend = try await connected(transport)
        await #expect(throws: ChatError.self) {
            _ = try await backend.participants(in: Conversation.ID("space/a"), after: nil)
        }
        await backend.disconnect()
    }

    @Test func permissionsAreReadAgainBeforeAWrittenChange() async throws {
        let transport = ManagementTransport()
        let backend = try await connected(transport)
        let id = Conversation.ID("space/a")
        let before = try await backend.conversationDetails(id)
        await transport.revoke()
        await #expect(throws: ChatError.self) {
            _ = try await backend.mutateConversation(
                .identity(name: "No longer allowed", description: nil, access: nil),
                in: id,
                operationID: "revoked",
                expectedRevision: before.revision
            )
        }
        let count = await transport.writes
        #expect(count == 0)
        await backend.disconnect()
    }
}
