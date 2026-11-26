import ChatKit
import Foundation
import GChatBridgeCore
import SwiftProtobuf
import Testing
@testable import LocalBridgeBackend

@Suite(.timeLimit(.minutes(1)))
struct StarredMessageBackendTests {
    @Test func readsAndConfirmsPersonalStarsThroughTheProviderTransport() async throws {
        let transport = StarredMessageTransport()
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        let address = MessageAddress(
            conversation: .init("space/a"), thread: .init("thread"), message: .init("sample")
        )
        #expect(try await backend.starredMessages(after: nil).messages.isEmpty)
        try await backend.setMessageStarred(true, at: address)
        let page = try await backend.starredMessages(after: nil)
        #expect(page.messages.map(MessageAddress.init) == [address])
        #expect(page.members.first?.displayName == "Casey")
        try await backend.setMessageStarred(false, at: address)
        #expect(try await backend.starredMessages(after: nil).messages.isEmpty)
        #expect(await transport.writes == ["apply_message_label", "remove_message_label"])
        await backend.disconnect()
    }
}

private actor StarredMessageTransport: HTTPTransport {
    let base = ActionTransport(kind: .space)
    private(set) var writes: [String] = []
    var starred = false

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let method = request.url.lastPathComponent
        let body = request.body ?? Data()
        switch method {
        case "paginated_world":
            let input = try PaginatedEntityWorldRequest(serializedBytes: body)
            guard let section = input.sections.first, section.hasEntityFilter else {
                return try await base.send(request)
            }
            var responseSection = WorldSectionResponse()
            responseSection.entityFilter = section.entityFilter
            var response = PaginatedWorldResponse()
            response.worldSectionResponses = [responseSection]
            if starred {
                var value = WorldEntity()
                value.message = message()
                response.worldEntities = [value]
            }
            return try ok(response)
        case "get_message":
            let input = try GetMessageRequest(serializedBytes: body)
            var response = GetMessageResponse()
            response.message = message()
            #expect(input.messageID == response.message.id)
            return try ok(response)
        case "apply_message_label", "remove_message_label":
            let input = try ApplyMessageLabelRequest(serializedBytes: body)
            #expect(input.messageID == message().id)
            #expect(input.label.labelType == 1 && !input.label.hasCreateTime)
            writes.append(method)
            starred = method == "apply_message_label"
            return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
        default:
            return try await base.send(request)
        }
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }

    private func message() -> GChatBridgeCore.Message {
        var value = GChatBridgeCore.Message()
        value.id = MessagePinRequests.address(
            group: WorldItemFixture.spaceGroupID("a"), topic: "thread", message: "sample"
        )
        value.messageType = .userMessage
        value.creator.userID.id = "person"
        value.creator.name = "Casey"
        value.textBody = "Starred sample"
        value.createTime = 1_700_000_000_000_000
        if starred {
            var label = MessageLabel()
            label.labelType = 1
            value.personalLabelTags = [label]
        }
        return value
    }

    private func ok(_ message: some SwiftProtobuf.Message) throws -> HTTPResponse {
        try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: message.serializedData())
    }
}
