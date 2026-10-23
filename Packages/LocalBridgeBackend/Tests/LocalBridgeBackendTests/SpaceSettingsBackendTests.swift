import ChatKit
import Foundation
import GChatBridgeCore
import SwiftProtobuf
import Testing
@testable import LocalBridgeBackend

private actor SpaceSettingsTransport: HTTPTransport {
    let base = ActionTransport(kind: .space)
    var group: Group
    var grants: [Int32] = [3, 14, 25, 26, 65, 67, 68, 73]
    var omitEcho = false
    var includeAudience = true
    private(set) var updates: [UpdateGroupRequest] = []

    init() throws {
        group = Group()
        group.groupID.spaceID.spaceID = "a"
        group.attributeCheckerGroupType = .flatRoom
        group.revisionTime = 1
        group.groupDetails.description_p = "Kept description"
        group.avatarInfo.emoji.unicode = "🐾"
        var rule = try SpacePermissionRule(serializedBytes: Data([0x48, 7]))
        rule.permission = 9
        rule.roles.owners = true; rule.roles.managers = true; rule.roles.members = true
        var future = SpacePermissionRule(); future.permission = 800
        future.roles.organization = true
        var visibility = rule; visibility.permission = 23
        var join = SpacePermissionRule(); join.permission = 22
        var find = rule; find.permission = 24; find.roles.organization = true
        var autoJoin = SpacePermissionRule(); autoJoin.permission = 25; autoJoin.roles.organization = true
        group.spacePermissions.rules = [rule, future, visibility, join, find, autoJoin]
    }

    func omitAudience() {
        includeAudience = false
    }

    func refuseSettings() {
        grants = []
    }

    func withoutEcho() {
        omitEcho = true
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch request.url.lastPathComponent {
        case "get_group":
            var response = GetGroupResponse()
            response.group = group
            if includeAudience {
                var audience = SpacePermissionAudience()
                audience.id.id = "organization-audience"; audience.name = "Example organization"; audience
                    .type = 1
                response.defaultTargetAudiences = [audience]
            }
            response.membershipState = .memberJoined
            return try ok(response)
        case "get_group_scoped_capabilities":
            let input = try GetGroupScopedCapabilitiesRequest(serializedBytes: request.body ?? Data())
            var caps = GroupScopedCapabilities()
            caps.id = input.membershipIds[0]; caps.capabilities = grants
            var response = GetGroupScopedCapabilitiesResponse(); response.capabilities = [caps]
            return try ok(response)
        case "update_group":
            let input = try UpdateGroupRequest(serializedBytes: request.body ?? Data())
            updates.append(input)
            if input.hasSpacePermissions {
                group.spacePermissions = input.spacePermissions
            }
            if input.hasAvatarInfo {
                group.avatarInfo = input.avatarInfo
            }
            group.revisionTime += 1
            var response = UpdateGroupResponse()
            response.group.groupID = input.groupID
            if !omitEcho {
                response.group = group
            }
            return try ok(response)
        default: return try await base.send(request)
        }
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }

    private func ok(_ value: some SwiftProtobuf.Message) throws -> HTTPResponse {
        try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: value.serializedData())
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SpaceSettingsBackendTests {
    @Test func policyEditKeepsUnknownRulesAndUnrelatedFieldsAndReplaysOnce() async throws {
        let transport = try SpaceSettingsTransport()
        let backend = try await connected(transport)
        let patch = ConversationSettingsPatch(permissions: ["manageMembers": .managers])
        let result = try await backend.mutateConversation(
            .settings(patch), in: .init("space/a"), operationID: "policies", expectedRevision: "1"
        )
        #expect(result.details?.settings?.permissions.first { $0.id == "manageMembers" }?
            .audience == .managers)
        let input = try #require(await transport.updates.first)
        #expect(input.updateMasks.map(\.rawValue) == [6])
        #expect(input.spacePermissions.rules[0].unknownFields.data == Data([0x48, 7]))
        #expect(input.spacePermissions.rules[1].permission == 800)
        #expect(input.spacePermissions.rules[1].roles.organization)
        #expect(!input.hasSpaceDetails && !input.hasAvatarInfo)
        let repeated = try await backend.mutateConversation(
            .settings(patch), in: .init("space/a"), operationID: "policies", expectedRevision: "1"
        )
        #expect(repeated == result)
        #expect(await transport.updates.count == 1)
        await backend.disconnect()
    }

    @Test func joinRequestsKeepExistingPolicies() async throws {
        let transport = try SpaceSettingsTransport()
        let backend = try await connected(transport)
        let result = try await backend.mutateConversation(
            .settings(.init(requestToJoin: true)),
            in: .init("space/a"), operationID: "access", expectedRevision: nil
        )
        #expect(result.details?.settings?.requestToJoin == true)
        let input = try #require(await transport.updates.first)
        #expect(input.updateMasks.map(\.rawValue) == [6])
        #expect(input.spacePermissions.rules.first { $0.permission == 22 }?.audiences.audiences.first?.id
            .id == "organization-audience")
        #expect(input.spacePermissions.rules.count == 6)
        await backend.disconnect()
    }

    @Test func presetsUseTheReturnedAudienceAndMissingAudienceRefusesWrites() async throws {
        let transport = try SpaceSettingsTransport()
        let backend = try await connected(transport)
        let result = try await backend.mutateConversation(
            .settings(.init(access: .open)), in: .init("space/a"), operationID: "open", expectedRevision: nil
        )
        #expect(result.details?.access == .open)
        let input = try #require(await transport.updates.first)
        for number: Int32 in [24, 25] {
            #expect(input.spacePermissions.rules.first { $0.permission == number }?.audiences.audiences.first?
                .id.id == "organization-audience")
        }
        await transport.omitAudience()
        let after = try await backend.conversationDetails(.init("space/a"))
        #expect(after.settings?.canChangeAccess == false)
        #expect(after.settings?.canChangeRequestToJoin == false)
        await #expect(throws: ChatError.self) {
            _ = try await backend.mutateConversation(
                .settings(.init(access: .restricted)), in: .init("space/a"), operationID: "missing",
                expectedRevision: nil
            )
        }
        #expect(await transport.updates.count == 1)
        await backend.disconnect()
    }

    @Test func currentPermissionRefusalAndUnknownPoliciesPreventDispatch() async throws {
        let transport = try SpaceSettingsTransport()
        let backend = try await connected(transport)
        let shown = try await backend.conversationDetails(.init("space/a"))
        #expect(shown.allowedActions.contains("settings"))
        await transport.refuseSettings()
        await #expect(throws: ChatError.self) {
            _ = try await backend.mutateConversation(
                .settings(.init(access: .open)), in: .init("space/a"), operationID: "refused",
                expectedRevision: nil
            )
        }
        #expect(await transport.updates.isEmpty)
        await backend.disconnect()
    }

    @Test func emojiClearRequiresAnEchoAndDoesNotRepeatUncertainWrite() async throws {
        let transport = try SpaceSettingsTransport()
        let backend = try await connected(transport)
        await transport.withoutEcho()
        await #expect(throws: ChatError.self) {
            _ = try await backend.mutateConversation(
                .emoji(""), in: .init("space/a"), operationID: "clear", expectedRevision: nil
            )
        }
        let replay = try await backend.mutateConversation(
            .emoji(""), in: .init("space/a"), operationID: "clear", expectedRevision: nil
        )
        #expect(!replay.isConfirmed)
        #expect(await transport.updates.count == 1)
        let input = try #require(await transport.updates.first)
        #expect(input.avatarInfo.emoji.hasUnicode && input.avatarInfo.emoji.unicode.isEmpty)
        #expect(!input.hasSpacePermissions && !input.hasSpaceDetails)
        await backend.disconnect()
    }

    private func connected(_ transport: SpaceSettingsTransport) async throws -> LocalBridgeBackend {
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        return backend
    }
}
