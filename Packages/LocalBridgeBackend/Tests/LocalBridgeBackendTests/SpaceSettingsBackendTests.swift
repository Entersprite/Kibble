import ChatKit
import Foundation
import GChatBridgeCore
import SwiftProtobuf
import Testing
@testable import LocalBridgeBackend

actor SpaceSettingsTransport: HTTPTransport {
    let base = ActionTransport(kind: .space)
    var group: Group
    var grants: [Int32] = [3, 14, 25, 26, 65, 67, 68, 73]
    var omitEcho = false
    var partialPolicyEcho = false
    var includeAudience = true
    var rejectUpdate = false
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

    var hasFutureRule: Bool {
        group.spacePermissions.rules.contains { $0.permission == 800 && $0.roles.organization }
    }

    func beginDiscoverableWithJoinRequests() {
        var audience = SpacePermissionAudience()
        audience.id.id = "organization-audience"; audience.name = "Example organization"; audience.type = 1
        for index in group.spacePermissions.rules.indices {
            let number = group.spacePermissions.rules[index].permission
            if number == 22 || number == 24 {
                group.spacePermissions.rules[index].audiences.audiences = [audience]
            }
        }
    }

    func refuseUpdate() {
        rejectUpdate = true
    }

    func omitAudience() {
        includeAudience = false
    }

    func refuseSettings() {
        grants = []
    }

    func echoOnlyUnchangedPolicies() {
        partialPolicyEcho = true
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
                audience.state = 1
                response.defaultTargetAudiences = [audience]
            }
            response.membershipState = .memberJoined
            return try ok(response)
        case "get_group_scoped_capabilities":
            let input = try GetGroupScopedCapabilitiesRequest(serializedBytes: request.body ?? Data())
            var caps = GroupScopedCapabilities()
            caps.id = input.membershipIds[0]; caps.capabilities = grants
            caps.permissions = try explicitManagementPermissions(grants)
            var response = GetGroupScopedCapabilitiesResponse(); response.capabilities = [caps]
            return try ok(response)
        case "update_group":
            return try update(request)
        default: return try await base.send(request)
        }
    }

    private func update(_ request: HTTPRequest) throws -> HTTPResponse {
        let input = try UpdateGroupRequest(serializedBytes: request.body ?? Data())
        updates.append(input)
        if rejectUpdate {
            let body = Data(#"""
            {"error":{"code":3,
              "message":"Invalid space_permissions for organization-audience secret@example.com",
              "details":"private server text"}}
            """#.utf8)
            return HTTPResponse(status: 400, headers: HTTPHeaders([]), body: body)
        }
        let access = Set(input.spacePermissions.rules.map(\.permission)).intersection([24, 25])
        if !access.isEmpty, access != [24, 25] {
            return HTTPResponse(
                status: 400,
                headers: HTTPHeaders([]),
                body: Data("Invalid request data".utf8)
            )
        }
        if input.hasSpacePermissions {
            for rule in input.spacePermissions.rules {
                group.spacePermissions.rules.removeAll { $0.permission == rule.permission }
                group.spacePermissions.rules.append(rule)
            }
        }
        if input.hasAvatarInfo {
            group.avatarInfo = input.avatarInfo
        }
        group.revisionTime += 1
        var response = UpdateGroupResponse()
        response.group.groupID = input.groupID
        if !omitEcho {
            response.group = group
            if partialPolicyEcho {
                response.group.spacePermissions.rules = group.spacePermissions.rules
                    .filter { $0.permission == 800 }
            }
        }
        return try ok(response)
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }

    private func ok(_ value: some SwiftProtobuf.Message) throws -> HTTPResponse {
        try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: value.serializedData())
    }
}

private final class ManagementWriteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ProviderDiagnostic] = []
    private var actions: [ConversationActionObservation] = []
    var requests: [ConversationActionObservation] {
        lock.withLock { actions }
    }

    func record(_ value: ConversationActionObservation) {
        lock.withLock { actions.append(value) }
    }

    var events: [ProviderDiagnostic] {
        lock.withLock { recorded }
    }

    var diagnostics: ProviderDiagnostics {
        ProviderDiagnostics { [self] event in lock.withLock { recorded.append(event) } }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SpaceSettingsBackendTests {
    @Test func settingsWritesDeclareTheirNativePolicyFeatures() async throws {
        let transport = try SpaceSettingsTransport()
        let backend = try await connected(transport)
        let result = try await backend.mutateConversation(
            .settings(.init(access: .open)), in: .init("space/a"),
            operationID: "negotiated-access", expectedRevision: "1"
        )
        #expect(result.isConfirmed)
        let request = try #require(await transport.updates.first)
        let header = try request.requestHeader.serializedData()
        let features = try #require(ProtoFieldScan.payloads(ofField: 5, in: header).first)
        // Native target audiences, join requests, manager roles, member visibility,
        // and join/discover policy support. These are client features, not edit grants.
        #expect(ProtoFieldScan.fields(in: features).fields.map(\.number) == [10, 37, 56, 64, 70])
        for field in [10, 37, 56, 64, 70] {
            #expect(ProtoFieldScan.varintValues(ofField: field, in: features) == [2])
        }
        #expect(!request.requestHeader.clientFeatureCapabilities.hasEnableAllFeatures)
        #expect(await transport.updates.count == 1)
        await backend.disconnect()
    }

    @Test func aRefusedUpdateIdentifiesTheFailingStageWithoutLoggingItsPayload() async throws {
        let transport = try SpaceSettingsTransport()
        let log = ManagementWriteLog()
        let backend = try await connected(transport, diagnostics: log.diagnostics)
        await backend.observeConversationActions { log.record($0) }
        await transport.refuseUpdate()
        await #expect(throws: APIFailure.self) {
            _ = try await backend.mutateConversation(
                .settings(.init(access: .open)), in: .init("space/a"),
                operationID: "refused-update", expectedRevision: "1"
            )
        }
        #expect(log.events.contains(.managementWrite(step: "settingsSnapshot", failure: nil)))
        #expect(log.events.contains(.managementWrite(step: "settingsRequest", failure: "http(400)")))
        #expect(!log.events.contains(.managementWrite(step: "settingsConfirmation", failure: nil)))
        #expect(!String(describing: log.events).contains("private server text"))
        #expect(await transport.updates.count == 1)
        let request = try #require(log.requests.first { $0.rpc == "update_group" })
        #expect(request.status == 400 && request.serviceCode == 3)
        let detail = try #require(request.management)
        #expect(detail.stage == "settingsRequest")
        #expect(detail.request?.updateMasks == [6])
        #expect(detail.request?.clientFeatureLevels == [10: 2, 37: 2, 56: 2, 64: 2, 70: 2])
        #expect(detail.request?.policies.map(\.number) == [25, 24])
        #expect(detail.request?.policies.allSatisfy { $0.defaultAudienceMatches == 1 } == true)
        #expect(detail.refusal?.message?.contains("space_permissions") == true)
        let exported = try String(decoding: JSONEncoder().encode(log.requests), as: UTF8.self)
        for secret in ["organization-audience", "secret@example.com", "private server text"] {
            #expect(!exported.contains(secret))
        }
        await backend.disconnect()
    }

    @Test func discoverableWithJoinRequestsCanBecomeOpenInOneWrite() async throws {
        let transport = try SpaceSettingsTransport()
        await transport.beginDiscoverableWithJoinRequests()
        let backend = try await connected(transport)
        let before = try await backend.conversationDetails(.init("space/a"))
        #expect(before.access == .discoverable && before.settings?.requestToJoin == true)
        let result = try await backend.mutateConversation(
            .settings(.init(access: .open, requestToJoin: false)), in: .init("space/a"),
            operationID: "open-from-discoverable", expectedRevision: before.revision
        )
        #expect(result.isConfirmed && result.details?.access == .open)
        #expect(result.details?.settings?.requestToJoin == false)
        let request = try #require(await transport.updates.first)
        #expect(Set(request.spacePermissions.rules.map(\.permission)) == [22, 24, 25])
        #expect(request.spacePermissions.rules.filter { [24, 25].contains($0.permission) }
            .allSatisfy { $0.audiences.audiences.first?.id.id == "organization-audience" })
        #expect(await transport.updates.count == 1)
        await backend.disconnect()
    }

    @Test func repeatedAccessChangesAlwaysSendBothAccessPolicies() async throws {
        let transport = try SpaceSettingsTransport()
        await transport.beginDiscoverableWithJoinRequests()
        let backend = try await connected(transport)
        for (index, access) in [ConversationAccess.open, .discoverable, .restricted, .discoverable, .open]
            .enumerated() {
            let result = try await backend.mutateConversation(
                .settings(.init(access: access, requestToJoin: index == 0 ? false : nil)),
                in: .init("space/a"),
                operationID: "access-\(index)", expectedRevision: nil
            )
            #expect(result.details?.access == access)
        }
        let requests = await transport.updates
        #expect(requests.count == 5)
        #expect(requests.allSatisfy {
            Set($0.spacePermissions.rules.map(\.permission)).intersection([24, 25]) == [24, 25]
        })
        await backend.disconnect()
    }

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
        #expect(input.spacePermissions.rules.map(\.permission) == [9])
        #expect(await transport.hasFutureRule)
        #expect(!input.hasSpaceDetails && !input.hasAvatarInfo)
        let repeated = try await backend.mutateConversation(
            .settings(patch), in: .init("space/a"), operationID: "policies", expectedRevision: "1"
        )
        #expect(repeated == result)
        #expect(await transport.updates.count == 1)
        await backend.disconnect()
    }

    @Test func aPartialPermissionEchoIsReadBackWithoutRepeatingTheWrite() async throws {
        let transport = try SpaceSettingsTransport()
        await transport.echoOnlyUnchangedPolicies()
        let backend = try await connected(transport)
        let mutation = ConversationMutation.settings(.init(permissions: ["manageMembers": .managers]))
        let result = try await backend.mutateConversation(
            mutation, in: .init("space/a"), operationID: "partial", expectedRevision: nil
        )
        #expect(result.isConfirmed)
        let replay = try await backend.mutateConversation(
            mutation, in: .init("space/a"), operationID: "partial", expectedRevision: nil
        )
        #expect(replay == result)
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
        let predicate = try #require(input.spacePermissions.rules.first { $0.permission == 22 }?
            .audiences.audiences.first)
        #expect(predicate.type == 1 && predicate.id.id.isEmpty)
        #expect(input.spacePermissions.rules.map(\.permission) == [22])
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

    @Test func emojiClearUsesReadBackWhenTheEchoIsSparse() async throws {
        let transport = try SpaceSettingsTransport()
        let backend = try await connected(transport)
        await transport.withoutEcho()
        let result = try await backend.mutateConversation(
            .emoji(""), in: .init("space/a"), operationID: "clear", expectedRevision: nil
        )
        let replay = try await backend.mutateConversation(
            .emoji(""), in: .init("space/a"), operationID: "clear", expectedRevision: nil
        )
        #expect(result.isConfirmed && replay == result)
        #expect(await transport.updates.count == 1)
        let input = try #require(await transport.updates.first)
        #expect(input.avatarInfo.emoji.hasUnicode && input.avatarInfo.emoji.unicode.isEmpty)
        #expect(!input.hasSpacePermissions && !input.hasSpaceDetails)
        await backend.disconnect()
    }

    func connected(
        _ transport: SpaceSettingsTransport, diagnostics: ProviderDiagnostics = .init()
    ) async throws -> LocalBridgeBackend {
        let backend = LocalBridgeBackend(
            cookies: SearchBackendSupport.cookies, transport: transport, diagnostics: diagnostics
        )
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        return backend
    }
}
