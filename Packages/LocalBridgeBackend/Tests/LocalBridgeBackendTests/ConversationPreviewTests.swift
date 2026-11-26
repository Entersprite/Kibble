import ChatKit
import Foundation
import GChatBridgeCore
import SwiftProtobuf
import Testing
@testable import LocalBridgeBackend

@Suite(.timeLimit(.minutes(1)))
struct ConversationPreviewTests {
    @Test func historyIsScopedBoundedSortedAndDoesNotUseReadOrJoinEndpoints() async throws {
        let transport = PreviewTransport()
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        let contract: any ChatBackend = backend
        let preview = try await contract.conversationPreview(.init("space/a"))
        #expect(preview.messages.count == 50)
        #expect(preview.messages.first?.text == "root-5")
        #expect(preview.messages.last?.text == "root-54")
        #expect(preview.messages.allSatisfy { $0.conversationID == .init("space/a") && !$0.isReply })
        let reads = await transport.paths
        #expect(reads.contains("list_topics"))
        #expect(!reads.contains("mark_group_readstate"))
        #expect(!reads.contains("create_membership"))
        await #expect(throws: ChatError.self) {
            _ = try await contract.conversationPreview(.init("dm/a"))
        }
        await backend.disconnect()
    }

    @Test func blockTargetsTheInvitedSpaceAndReplaysOnlyItsConfirmedResult() async throws {
        let transport = PreviewTransport()
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        let id = Conversation.ID("space/a")
        let details = try await backend.conversationDetails(id)
        #expect(details.membership == .invited && details.allowedActions.contains("block"))
        let result = try await backend.mutateConversation(
            .block,
            in: id,
            operationID: "block-one",
            expectedRevision: nil
        )
        #expect(result.isConfirmed)
        #expect(result.details?.allowedActions.isEmpty == true)
        #expect(try await backend.mutateConversation(
            .block,
            in: id,
            operationID: "block-one",
            expectedRevision: nil
        ) == result)
        let requests = await transport.blocks
        #expect(requests.count == 1)
        #expect(requests.first?.groupID.spaceID.spaceID == "a")
        await backend.disconnect()
    }
}

private actor PreviewTransport: HTTPTransport {
    let base = ActionTransport(kind: .space)
    var paths: [String] = []
    var blocks: [BlockEntityRequest] = []

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.url.lastPathComponent
        paths.append(path)
        switch path {
        case "get_group":
            var response = GetGroupResponse()
            response.group.groupID.spaceID.spaceID = "a"
            response.group.attributeCheckerGroupType = .flatRoom
            response.membershipState = .memberInvited
            return try ok(response)
        case "list_topics":
            var response = ListTopicsResponse()
            let roots = (0 ..< 55).reversed().map { message($0) }
            var topic = Topic()
            topic.replies = roots + [message(99, reply: true), message(100, space: "other")]
            response.topics = [topic]
            return try ok(response)
        case "get_members": return try ok(GetMembersResponse())
        case "block_entity":
            try blocks.append(BlockEntityRequest(serializedBytes: request.body ?? Data()))
            var response = BlockEntityResponse()
            response.readState.blocked = true
            return try ok(response)
        default: return try await base.send(request)
        }
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }

    private func message(_ index: Int, space: String = "a", reply: Bool = false) -> GChatBridgeCore.Message {
        var message = GChatBridgeCore.Message()
        message.id.messageID = "m-\(index)"
        message.id.parentID.topicID.topicID = "m-\(index)"
        message.id.parentID.topicID.groupID.spaceID.spaceID = space
        message.creator.userID.id = "author"
        message.textBody = "root-\(index)"
        message.createTime = Int64(1_700_000_000_000_000 + index)
        message.isInlineReply = reply
        return message
    }

    private func ok(_ value: some SwiftProtobuf.Message) throws -> HTTPResponse {
        try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: value.serializedData())
    }
}
