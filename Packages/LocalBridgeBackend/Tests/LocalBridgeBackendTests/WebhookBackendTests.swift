import ChatKit
import Foundation
import GChatBridgeCore
import SwiftProtobuf
import Testing
@testable import LocalBridgeBackend

actor WebhookTransport: HTTPTransport {
    let base = ActionTransport(kind: .space)
    var hooks: [IncomingWebhook] = []
    var grants: [Int32] = [30, 35]
    var apps: [String] = []
    var email: SpaceEmailDetails?
    var viewerOwner = true
    var groupType: SharedAttributeCheckerGroupType = .flatRoom
    var groupName = "Room"
    var groupEmoji: String?
    var openedAppID: String?

    var omitAvatarEcho = false
    private(set) var writes = 0

    init() throws {
        var group = GroupId(); group.spaceID.spaceID = "a"
        var hook = IncomingWebhook()
        hook.id.group = try WebhookRequests.groupReference(group); hook.id.id = "first"
        hook.name = "Builds"; hook.avatarURL = ""; hook.token = "private-token"
        hook.url = "https://example.invalid/hooks/first?key=private-delivery-key"
        hooks = [hook]
    }

    func enableEmail(owner: Bool = true) {
        grants += [46, 48]; viewerOwner = owner
    }

    func enableConversion() {
        grants += [55]; groupType = .immutableMembershipGroupDm
    }

    func enableApps() {
        grants += [21, 33]; apps = ["installed-app"]
    }

    func revoke() {
        grants = []
    }

    func omitEcho() {
        omitAvatarEcho = true
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch request.url.lastPathComponent {
        case "get_group":
            let input = try GetGroupRequest(serializedBytes: request.body ?? Data())
            var response = GetGroupResponse()
            response.group.groupID = input.groupID; response.group.name = groupName
            response.group.attributeCheckerGroupType = groupType; response.membershipState = .memberJoined
            if let groupEmoji {
                response.group.avatarInfo.emoji.unicode = groupEmoji
            }
            return try native(response)
        case "get_group_scoped_capabilities":
            let input = try GetGroupScopedCapabilitiesRequest(serializedBytes: request.body ?? Data())
            var caps = GroupScopedCapabilities(); caps.id = input.membershipIds[0]; caps.capabilities = grants
            var response = GetGroupScopedCapabilitiesResponse(); response.capabilities = [caps]
            return try native(response)
        case "get_membership":
            let input = try GetMembershipRequest(serializedBytes: request.body ?? Data())
            var response = GetMembershipResponse()
            response.memberships = input.membershipIds.map { id in
                var row = Membership(); row.id = id
                row.membershipState = .memberJoined; row
                    .membershipRole = viewerOwner ? .roleOwner : .roleManager
                return row
            }
            return try native(response)
        case "batchexecute": return try batch(request)
        default:
            if let response = try emailResponse(request) {
                return response
            }
            if let response = try appResponse(request) {
                return response
            }
            return try await base.send(request)
        }
    }

    private func emailResponse(_ request: HTTPRequest) throws -> HTTPResponse? {
        switch request.url.lastPathComponent {
        case "list_emailable_space_details":
            let input = try ListSpaceEmailRequest(serializedBytes: request.body ?? Data())
            var response = ListSpaceEmailResponse(); response.group = input.group
            response.canGenerate = true; response.details = email.map { [$0] } ?? []
            return try native(response)
        case "generate_space_email":
            let input = try ListSpaceEmailRequest(serializedBytes: request.body ?? Data())
            var value = try SpaceEmailDetails(serializedBytes: Data([0x48, 7]))
            value.email = "room@example.invalid"; value.emailDeliverySetting = 2
            email = value; writes += 1
            var response = GenerateSpaceEmailResponse(); response.group = input.group; response
                .details = [value]
            return try native(response)
        case "update_emailable_space_details":
            let input = try UpdateSpaceEmailRequest(serializedBytes: request.body ?? Data())
            #expect(input.updateMask.paths == ["emailable_space_details.email_delivery_setting"])
            #expect(input.details.unknownFields.data == Data([0x48, 7]))
            email = input.details; writes += 1
            var response = UpdateSpaceEmailResponse(); response.details = input.details
            return try native(response)
        case "delete_space_email":
            email = nil; writes += 1
            return try native(DeleteSpaceEmailResponse())
        default: return nil
        }
    }

    private func appResponse(_ request: HTTPRequest) throws -> HTTPResponse? {
        switch request.url.lastPathComponent {
        case "list_members":
            let input = try ListMembersRequest(serializedBytes: request.body ?? Data())
            var response = ListMembersResponse(); response.nextPageToken = ""
            let appIDs = input.groupID.dmID.dmID == "app-dm" ? openedAppID.map { [$0] } ?? [] : apps
            response.memberships = appIDs.map { id in
                var row = Membership()
                row.id.groupID = input.groupID; row.id.memberID = ChatAppRequests.member(id)
                row.membershipState = .memberJoined
                return row
            }
            return try native(response)
        case "get_members":
            let input = try GetMembersRequest(serializedBytes: request.body ?? Data())
            var response = GetMembersResponse()
            response.members = input.memberIds.map { id in
                var member = GChatBridgeCore.Member()
                member.user.userID = id.userID; member.user.name = "Build Monitor"
                return member
            }
            return try native(response)
        case "create_bot_dm":
            let input = try CreateBotDmRequest(serializedBytes: request.body ?? Data())
            #expect(input.bot.type == .bot)
            openedAppID = input.bot.id
            var response = CreateDmResponse()
            response.dm.groupID.dmID.dmID = "app-dm"
            response.dm.attributeCheckerGroupType = .oneToOneBotDm
            return try native(response)
        default: return try appMembershipResponse(request)
        }
    }

    private func appMembershipResponse(_ request: HTTPRequest) throws -> HTTPResponse? {
        switch request.url.lastPathComponent {
        case "create_membership":
            let input = try CreateMembershipRequest(serializedBytes: request.body ?? Data())
            #expect(input.memberIds.count == 1 && input.memberIds[0].userID.type == .bot)
            apps.append(input.memberIds[0].userID.id); writes += 1
            var response = CreateMembershipResponse()
            var result = CreateMembershipResult()
            result.membership.id.groupID = input.groupID; result.membership.id.memberID = input.memberIds[0]
            result.membership.membershipState = .memberJoined
            response.results = [result]
            return try native(response)
        case "remove_memberships":
            let input = try RemoveMembershipsRequest(serializedBytes: request.body ?? Data())
            let member = try #require(input.memberIds.first)
            #expect(member.userID.type == .bot)
            apps.removeAll { $0 == member.userID.id }; writes += 1
            var response = RemoveMembershipsResponse()
            var result = RemoveMembershipResult()
            result.memberID = member
            response.results = [result]
            return try native(response)
        default: return nil
        }
    }

    private func batch(_ request: HTTPRequest) throws -> HTTPResponse {
        let rpc = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "rpcids" }?.value ?? ""
        let form = String(decoding: request.body ?? Data(), as: UTF8.self)
        let envelope = URLComponents(string: "https://example.invalid/?" + form)?.queryItems?
            .first { $0.name == "f.req" }?.value ?? ""
        let outer = try PBLiteValue(json: Data(envelope.utf8))
        let payload = try #require(outer.arrayValue?.first?.arrayValue?.first?.arrayValue?[1].stringValue)
        let value = try PBLiteValue(json: Data(payload.utf8))
        let answer: PBLiteValue
        switch rpc {
        case "yVxlUd":
            var response = GetIncomingWebhooksResponse(); response.webhooks = hooks
            answer = try PBLiteEncoder.encode(response)
        case "yljFfb":
            let input = PBLiteDecoder.decode(CreateIncomingWebhookRequest.self, from: value).message
            var hook = IncomingWebhook(); hook.id.group = input.group; hook.id.id = "new"
            hook.name = input.name; hook.avatarURL = input.avatarURL
            hooks.append(hook); writes += 1
            if omitAvatarEcho {
                hook.clearAvatarURL()
            }
            var response = IncomingWebhookResponse(); response.webhook = hook
            answer = try PBLiteEncoder.encode(response)
        case "W7SEjd":
            let input = PBLiteDecoder.decode(UpdateIncomingWebhookRequest.self, from: value).message
            let index = try #require(hooks.firstIndex { $0.id == input.id })
            hooks[index].name = input.name; hooks[index].avatarURL = input.avatarURL; writes += 1
            var response = IncomingWebhookResponse(); response.webhook = hooks[index]
            answer = try PBLiteEncoder.encode(response)
        case "ITXKid":
            let input = PBLiteDecoder.decode(DeleteIncomingWebhookRequest.self, from: value).message
            hooks.removeAll { $0.id == input.id }; writes += 1; answer = .array([])
        default: answer = try appBatch(rpc, value: value)
        }
        let inner = try #require(JSONSerialization.jsonObject(with: answer.jsonData()) as? [Any])
        return try HTTPResponse(
            status: 200,
            headers: HTTPHeaders([]),
            body: SearchFixtures.answerBody(inner: inner, rpc: rpc)
        )
    }

    private func appBatch(_ rpc: String, value: PBLiteValue) throws -> PBLiteValue {
        switch rpc {
        case "JpvLpe":
            let input = PBLiteDecoder.decode(ConvertChatToSpaceRequest.self, from: value).message
            #expect(input.attributes.first?.type == 6 && input.attributes.first?.value == "SPACE")
            groupType = .flatRoom; groupName = input.name
            if input.hasAvatar {
                groupEmoji = input.avatar.emoji.unicode
            }
            writes += 1; return .array([])
        case "wxhTDd":
            #expect(try value.jsonString() == #"["build",null,null,null,null,[1]]"#)
            var response = SearchChatAppsResponse()
            response.users = ["installed-app", "available-app"].map { id in
                var user = WebAppUser()
                user.id.rawID = id; user.id.id = "bot/" + id; user.id.kind = 1
                user.name = "Build Monitor"; user.appInfo.description_p = "Build notifications"
                return user
            }
            return try PBLiteEncoder.encode(response)
        default: throw ChatError.decoding("Unexpected integration request.")
        }
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }

    private func native(_ value: some SwiftProtobuf.Message) throws -> HTTPResponse {
        try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: value.serializedData())
    }
}

@Suite(.timeLimit(.minutes(1)))
struct WebhookBackendTests {
    @Test func listingOmitsSecretsAndDeliveryURLRequiresCurrentPermission() async throws {
        let transport = try WebhookTransport(); let backend = try await connected(transport)
        let listing = try await backend.conversationIntegrations(.init("space/a"))
        let hook = try #require(listing.webhooks.first)
        let encoded = try String(decoding: JSONEncoder().encode(listing), as: UTF8.self)
        #expect(!encoded.contains("private-token") && !encoded.contains("private-delivery-key"))
        #expect(try await backend.webhookDeliveryURL(hook.id, in: .init("space/a")).query?
            .contains("private-delivery-key") == true)
        await transport.revoke()
        await #expect(throws: ChatError.self) { _ = try await backend.webhookDeliveryURL(
            hook.id,
            in: .init("space/a")
        ) }
        await backend.disconnect()
    }

    @Test func foreignWebhookCannotBeUpdatedAndPermissionRevocationPreventsWrite() async throws {
        let transport = try WebhookTransport(); let backend = try await connected(transport)
        var foreign = WebhookReference(); foreign.group.id = "space/other"; foreign.id = "first"
        let id = try foreign.serializedData().base64EncodedString()
        await #expect(throws: ChatError.self) {
            _ = try await backend.mutateConversation(
                .deleteWebhook(id),
                in: .init("space/a"),
                operationID: "foreign",
                expectedRevision: nil
            )
        }
        await transport.revoke()
        await #expect(throws: ChatError.self) {
            _ = try await backend.mutateConversation(
                .saveWebhook(id: nil, name: "Builds", avatarURL: ""),
                in: .init("space/a"),
                operationID: "revoked",
                expectedRevision: nil
            )
        }
        #expect(await transport.writes == 0)
        await backend.disconnect()
    }

    @Test func createEditAndDeleteAreConfirmedAndReplayDoesNotResubmit() async throws {
        let transport = try WebhookTransport(); let backend = try await connected(transport)
        let mutation = ConversationMutation.saveWebhook(id: nil, name: "Deploys", avatarURL: "")
        let first = try await backend.mutateConversation(
            mutation,
            in: .init("space/a"),
            operationID: "create",
            expectedRevision: nil
        )
        #expect(first.isConfirmed)
        #expect(try await backend.mutateConversation(
            mutation,
            in: .init("space/a"),
            operationID: "create",
            expectedRevision: nil
        ) == first)
        let rows = try await backend.conversationIntegrations(.init("space/a"))
        let id = try #require(rows.webhooks.first { $0.name == "Deploys" }?.id)
        _ = try await backend.mutateConversation(
            .saveWebhook(id: id, name: "Releases", avatarURL: ""),
            in: .init("space/a"),
            operationID: "edit",
            expectedRevision: nil
        )
        _ = try await backend.mutateConversation(
            .deleteWebhook(id),
            in: .init("space/a"),
            operationID: "delete",
            expectedRevision: nil
        )
        #expect(await transport.writes == 3)
        #expect(try await backend.conversationIntegrations(.init("space/a")).webhooks.count == 1)
        await backend.disconnect()
    }

    @Test func missingCreateEchoStaysUncertainWithoutDuplicatingWebhook() async throws {
        let transport = try WebhookTransport(); let backend = try await connected(transport)
        await transport.omitEcho()
        let mutation = ConversationMutation.saveWebhook(id: nil, name: "Deploys", avatarURL: "")
        await #expect(throws: ChatError.self) { _ = try await backend.mutateConversation(
            mutation,
            in: .init("space/a"),
            operationID: "create",
            expectedRevision: nil
        ) }
        #expect(try await backend.mutateConversation(
            mutation,
            in: .init("space/a"),
            operationID: "create",
            expectedRevision: nil
        ).isConfirmed == false)
        #expect(await transport.writes == 1)
        await backend.disconnect()
    }

    private func connected(_ transport: WebhookTransport) async throws -> LocalBridgeBackend {
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect(); try await SearchBackendSupport.waitForSelf(backend)
        return backend
    }
}
