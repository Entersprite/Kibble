import ChatKit
import Foundation
import GChatBridgeCore
import SwiftProtobuf
import Testing
@testable import LocalBridgeBackend

private actor AuthorityTransport: HTTPTransport {
    let base = ActionTransport(kind: .space)
    var viewerRole: MembershipRole = .roleOwner
    var viewerState: MembershipState = .memberJoined
    var foreignViewer = false
    var foreignTarget = false
    var roleGrants = false
    var otherOwner = true
    var profileMetadata = false
    var blocked: [String: Bool] = [:]
    private(set) var roleWrites = 0
    private(set) var blockWrites = 0

    func enableRoles(otherOwner: Bool) {
        roleGrants = true; self.otherOwner = otherOwner
    }

    func enableMetadata() {
        profileMetadata = true
    }

    func replaceTargetScope() {
        foreignTarget = true
    }

    private(set) var removals = 0
    private(set) var viewerReads = 0

    func configure(role: MembershipRole, state: MembershipState, foreign: Bool) {
        viewerRole = role
        viewerState = state
        foreignViewer = foreign
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch request.url.lastPathComponent {
        case "get_group":
            let input = try GetGroupRequest(serializedBytes: request.body ?? Data())
            var response = GetGroupResponse()
            response.group.groupID = input.groupID
            response.group.attributeCheckerGroupType = .flatRoom
            response.membershipState = .memberJoined
            return try ok(response)
        case "get_group_scoped_capabilities":
            let input = try GetGroupScopedCapabilitiesRequest(serializedBytes: request.body ?? Data())
            var response = GetGroupScopedCapabilitiesResponse()
            var caps = GroupScopedCapabilities()
            caps.id = input.membershipIds[0]
            caps.capabilities = roleGrants ? [2, 4, 60] : [4]
            response.capabilities = [caps]
            return try ok(response)
        case "list_members":
            let input = try ListMembersRequest(serializedBytes: request.body ?? Data())
            var response = ListMembersResponse()
            response.memberships = [membership(
                "peer",
                group: input.groupID,
                role: otherOwner ? .roleOwner : .roleMember
            )]
            if roleGrants {
                response.memberships.append(membership(
                    "me",
                    group: input.groupID,
                    role: viewerRole
                ))
            }
            return try ok(response)
        case "get_members":
            return try profileResponse(request)
        default:
            if let response = try await membershipResponse(request) {
                return response
            }
            return try await base.send(request)
        }
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }

    private func membershipResponse(_ request: HTTPRequest) async throws -> HTTPResponse? {
        switch request.url.lastPathComponent {
        case "get_membership":
            let input = try GetMembershipRequest(serializedBytes: request.body ?? Data())
            let wanted = input.membershipIds[0]
            var response = GetMembershipResponse()
            if wanted.memberID.userID.id == "me" {
                viewerReads += 1
                var row = membership("me", group: wanted.groupID, role: viewerRole)
                row.membershipState = viewerState
                if foreignViewer {
                    row.id.groupID.spaceID.spaceID = "foreign"
                }
                response.memberships = [row]
            } else {
                var peer = membership(
                    "peer",
                    group: wanted.groupID,
                    role: otherOwner ? .roleOwner : .roleMember
                )
                if foreignTarget {
                    peer.id.groupID.spaceID.spaceID = "other"
                }
                response.memberships = [peer]
            }
            return try ok(response)
        case "update_membership_role": return try roleResponse(request)
        case "block_entity":
            let input = try BlockEntityRequest(serializedBytes: request.body ?? Data())
            guard case let .userID(user) = input.entity
            else { throw ChatError.decoding("Expected a person.") }
            blocked[user.id] = input.blocked; blockWrites += 1
            #expect(!input.reported)
            var response = BlockEntityResponse(); response.userRevision.timestamp = 1
            return try ok(response)
        case "remove_memberships":
            removals += 1
            return try await base.send(request)
        default: return nil
        }
    }

    private func roleResponse(_ request: HTTPRequest) throws -> HTTPResponse {
        let input = try UpdateMembershipRoleRequest(serializedBytes: request.body ?? Data())
        let change = try #require(input.changes.first)
        roleWrites += 1
        if change.userID.id == "me" {
            viewerRole = change.role
        } else {
            otherOwner = change.role == .roleOwner
        }
        var result = UpdateMembershipRoleResponse.Result()
        result.membership = membership(change.userID.id, group: change.groupID, role: change.role)
        var response = UpdateMembershipRoleResponse(); response.results = [result]
        return try ok(response)
    }

    private func profileResponse(_ request: HTTPRequest) throws -> HTTPResponse {
        let input = try GetMembersRequest(serializedBytes: request.body ?? Data())
        var response = GetMembersResponse()
        response.members = input.memberIds.map { id in
            var member = GChatBridgeCore.Member()
            member.user.userID = id.userID
            if profileMetadata {
                member.user.organizationInfo.customerInfo.customerID.customerID = id.userID
                    .id == "me" ? "org-a" : "org-b"
                member.user.blockRelationship.isBlockedByRequester = blocked[id.userID.id] ?? false
            }
            return member
        }
        return try ok(response)
    }

    private func membership(_ user: String, group: GroupId, role: MembershipRole) -> Membership {
        var row = Membership()
        row.id = ConversationManagementRequests.membershipID(group: group, user: user)
        row.membershipRole = role
        row.membershipState = .memberJoined
        return row
    }

    private func ok(_ value: some SwiftProtobuf.Message) throws -> HTTPResponse {
        try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: value.serializedData())
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ManagementAuthorityTests {
    @Test func theLastSpaceOwnerCannotLeaveUntilAnotherOwnerIsConfirmed() async throws {
        let transport = AuthorityTransport()
        await transport.enableRoles(otherOwner: false)
        let backend = try await connected(transport)
        let lastOwner = try await backend.conversationDetails(.init("space/a"))
        #expect(!lastOwner.allowedActions.contains("leave"))
        await #expect(throws: ChatError.self) {
            _ = try await backend.mutateConversation(
                .leave, in: .init("space/a"), operationID: "last-owner-leave", expectedRevision: nil
            )
        }
        await transport.enableRoles(otherOwner: true)
        let coOwner = try await backend.conversationDetails(.init("space/a"))
        #expect(coOwner.allowedActions.contains("leave"))
        await backend.disconnect()
    }

    @Test func ownerCanRemoveOwnerWhenViewerIsAbsentFromThePage() async throws {
        let transport = AuthorityTransport()
        let backend = try await connected(transport)
        let page = try await backend.participants(in: .init("space/a"), after: nil)
        #expect(page.participants.first?.allowedActions.contains("removePerson") == true)
        let result = try await backend.mutateConversation(
            .removePerson(.init("peer")), in: .init("space/a"), operationID: "remove-owner",
            expectedRevision: nil
        )
        #expect(result.isConfirmed)
        #expect(await transport.removals == 1)
        #expect(await transport
            .viewerReads == 4) // Info also rechecks leave authority before/after the write.
        await backend.disconnect()
    }

    @Test(arguments: [0, 1, 2])
    func writeRechecksViewerInsteadOfTrustingTheDisplayedPage(_ variant: Int) async throws {
        let transport = AuthorityTransport()
        let backend = try await connected(transport)
        let page = try await backend.participants(in: .init("space/a"), after: nil)
        #expect(page.participants.first?.allowedActions.contains("removePerson") == true)
        await transport.configure(
            role: variant == 0 ? .roleManager : .roleOwner,
            state: variant == 1 ? .memberInvited : .memberJoined,
            foreign: variant == 2
        )
        await #expect(throws: ChatError.self) {
            _ = try await backend.mutateConversation(
                .removePerson(.init("peer")), in: .init("space/a"), operationID: "refused-owner",
                expectedRevision: nil
            )
        }
        #expect(await transport.removals == 0)
        await backend.disconnect()
    }

    @Test func ownerPromotionAndSelfDemotionRecheckAnotherJoinedOwner() async throws {
        let transport = AuthorityTransport()
        await transport.enableRoles(otherOwner: false)
        let backend = try await connected(transport)
        await #expect(throws: ChatError.self) {
            _ = try await backend.mutateConversation(
                .setRole(.init("me"), .member),
                in: .init("space/a"),
                operationID: "last-owner",
                expectedRevision: nil
            )
        }
        #expect(await transport.roleWrites == 0)
        _ = try await backend.mutateConversation(
            .setRole(.init("peer"), .owner),
            in: .init("space/a"),
            operationID: "promote",
            expectedRevision: nil
        )
        _ = try await backend.mutateConversation(
            .setRole(.init("me"), .member),
            in: .init("space/a"),
            operationID: "demote-self",
            expectedRevision: nil
        )
        #expect(await transport.roleWrites == 2)
        await #expect(throws: ChatError.self) {
            _ = try await backend.mutateConversation(
                .setRole(.init("peer"), .member),
                in: .init("space/a"),
                operationID: "not-owner",
                expectedRevision: nil
            )
        }
        #expect(await transport.roleWrites == 2)
        await backend.disconnect()
    }

    @Test func blockPreservesMembershipAndRequiresAValidScopedHuman() async throws {
        let transport = AuthorityTransport()
        await transport.enableMetadata()
        let backend = try await connected(transport)
        let before = try await backend.participants(in: .init("space/a"), after: nil)
        #expect(before.participants.first?.isExternal == true)
        #expect(before.participants.first?.isBlocked == false)
        let mutation = ConversationMutation.setPersonBlocked(.init("peer"), true)
        let result = try await backend.mutateConversation(
            mutation,
            in: .init("space/a"),
            operationID: "block",
            expectedRevision: nil
        )
        #expect(try await backend.mutateConversation(
            mutation,
            in: .init("space/a"),
            operationID: "block",
            expectedRevision: nil
        ) == result)
        let after = try await backend.participants(in: .init("space/a"), after: nil)
        #expect(after.participants.count == before.participants.count)
        #expect(after.participants.first?.isBlocked == true)
        #expect(after.participants.first?.allowedActions.contains("unblockPerson") == true)
        await transport.replaceTargetScope()
        await #expect(throws: ChatError.self) {
            _ = try await backend.mutateConversation(
                .setPersonBlocked(.init("peer"), false),
                in: .init("space/a"),
                operationID: "foreign",
                expectedRevision: nil
            )
        }
        #expect(await transport.blockWrites == 1)
        await backend.disconnect()
    }

    private func connected(_ transport: AuthorityTransport) async throws -> LocalBridgeBackend {
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        return backend
    }
}
