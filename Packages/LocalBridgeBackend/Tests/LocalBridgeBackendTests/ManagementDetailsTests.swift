import ChatKit
import Foundation
import GChatBridgeCore
import SwiftProtobuf
import Testing
@testable import LocalBridgeBackend

private actor DetailsTransport: HTTPTransport {
    let base = ActionTransport(kind: .space)
    var details: GroupDetails
    var revision: Int64 = 1
    var name = "Room"
    var avatar = SpaceAvatar()
    var changeBeforeWrite = false
    var omitDetailsEcho = false
    private(set) var updates: [UpdateGroupRequest] = []
    private var reads = 0

    init() throws {
        // An unrecognized string field must survive an edit to a known one.
        details = try GroupDetails(serializedBytes: Data([0x4A, 3, 110, 101, 119]))
        details.description_p = "Original description"
        details.guidelines = "Original guidelines"
        avatar = try SpaceAvatar(serializedBytes: Data([0x48, 7])); avatar.emoji.unicode = "🐾"
    }

    func changeDuringPreflight() {
        changeBeforeWrite = true
    }

    func omitEmptyDetailsEcho() {
        details.description_p = ""
        details.guidelines = ""
        omitDetailsEcho = true
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch request.url.lastPathComponent {
        case "get_group":
            reads += 1
            if changeBeforeWrite, reads == 2 {
                revision += 1
            }
            let input = try GetGroupRequest(serializedBytes: request.body ?? Data())
            var response = GetGroupResponse()
            response.group.groupID = input.groupID
            response.group.name = name; response.group.avatarInfo = avatar
            response.group.groupDetails = details
            response.group.revisionTime = revision
            response.group.attributeCheckerGroupType = .flatRoom
            response.membershipState = .memberJoined
            return try ok(response)
        case "get_group_scoped_capabilities":
            let input = try GetGroupScopedCapabilitiesRequest(serializedBytes: request.body ?? Data())
            var caps = GroupScopedCapabilities()
            caps.id = input.membershipIds[0]
            caps.capabilities = [3, 6, 8]
            var response = GetGroupScopedCapabilitiesResponse()
            response.capabilities = [caps]
            return try ok(response)
        case "update_group":
            let input = try UpdateGroupRequest(serializedBytes: request.body ?? Data())
            updates.append(input)
            if input.hasSpaceDetails {
                details = input.spaceDetails
            }
            if input.hasName {
                name = input.name
            }
            if input.hasAvatarInfo {
                avatar = input.avatarInfo
            }
            revision += 1
            var response = UpdateGroupResponse()
            response.group.groupID = input.groupID
            response.group.name = name
            if input.hasAvatarInfo {
                response.group.avatarInfo = avatar
            }
            if !omitDetailsEcho {
                response.group.groupDetails = details
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
struct ManagementDetailsTests {
    @Test func oneDetailsSaveCombinesFieldsAndPreservesUnknownReplacementData() async throws {
        let transport = try DetailsTransport()
        let backend = try await connected(transport)
        let patch = ConversationDetailsPatch(
            name: "Planning",
            description: "Description",
            guidelines: "Guidelines",
            emoji: "🎉"
        )
        let result = try await backend.mutateConversation(
            .details(patch),
            in: .init("space/a"),
            operationID: "details",
            expectedRevision: "1"
        )
        #expect(result.isConfirmed && result.details?.description == "Description")
        let request = try #require(await transport.updates.first)
        #expect(request.updateMasks.map(\.rawValue) == [1, 4, 3])
        #expect(request.spaceDetails.unknownFields.data == Data([0x4A, 3, 110, 101, 119]))
        #expect(request.avatarInfo.unknownFields.data == Data([0x48, 7]))
        #expect(await transport.updates.count == 1)
        await backend.disconnect()
    }

    @Test func missingEchoDoesNotConfirmAnExplicitClearOrRepeatIt() async throws {
        let transport = try DetailsTransport()
        await transport.omitEmptyDetailsEcho()
        let backend = try await connected(transport)
        await #expect(throws: ChatError.self) {
            _ = try await backend.mutateConversation(
                .guidelines(""), in: .init("space/a"), operationID: "uncertain", expectedRevision: nil
            )
        }
        let replay = try await backend.mutateConversation(
            .guidelines(""), in: .init("space/a"), operationID: "uncertain", expectedRevision: nil
        )
        #expect(!replay.isConfirmed)
        #expect(await transport.updates.count == 1)
        await backend.disconnect()
    }

    @Test func descriptionEditPreservesGuidelinesAndUnknownFields() async throws {
        let transport = try DetailsTransport()
        let backend = try await connected(transport)
        let result = try await backend.mutateConversation(
            .identity(name: nil, description: "Changed description", access: nil),
            in: .init("space/a"), operationID: "describe", expectedRevision: nil
        )
        #expect(result.details?.description == "Changed description")
        #expect(result.details?.guidelines == "Original guidelines")
        let update = try #require(await transport.updates.first)
        #expect(update.updateMasks == [.spaceDetails])
        #expect(update.spaceDetails.unknownFields.data == Data([0x4A, 3, 110, 101, 119]))
        await backend.disconnect()
    }

    @Test func explicitGuidelinesClearKeepsDescriptionAndIsNotRepeated() async throws {
        let transport = try DetailsTransport()
        let backend = try await connected(transport)
        let result = try await backend.mutateConversation(
            .guidelines(""), in: .init("space/a"), operationID: "guidelines", expectedRevision: nil
        )
        #expect(result.details?.guidelines == "")
        #expect(result.details?.description == "Original description")
        let replay = try await backend.mutateConversation(
            .guidelines(""), in: .init("space/a"), operationID: "guidelines", expectedRevision: nil
        )
        #expect(replay == result)
        #expect(await transport.updates.count == 1)
        await backend.disconnect()
    }

    @Test func changedDetailsAreRefusedBeforeTheProviderWrite() async throws {
        let transport = try DetailsTransport()
        await transport.changeDuringPreflight()
        let backend = try await connected(transport)
        await #expect(throws: ChatError.self) {
            _ = try await backend.mutateConversation(
                .guidelines("new"), in: .init("space/a"), operationID: "stale", expectedRevision: nil
            )
        }
        #expect(await transport.updates.isEmpty)
        await backend.disconnect()
    }

    private func connected(_ transport: DetailsTransport) async throws -> LocalBridgeBackend {
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        return backend
    }
}
