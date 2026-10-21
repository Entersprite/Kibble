import Foundation
import GChatBridgeCore
import SwiftProtobuf

actor ProviderRecoveryTransport: HTTPTransport {
    var groupRevision: Int64 = 12
    var userRevision: Int64 = 20
    var replies: [CatchUpResponse] = []
    var hold = false
    var held = false
    var waiter: CheckedContinuation<Void, Never>?
    var holdMessages = false
    var messagesHeld = false
    var messageWaiter: CheckedContinuation<Void, Never>?
    var streams: [AsyncThrowingStream<Data, any Error>.Continuation] = []
    private(set) var froms: [Int64] = []

    func configure(replies: [CatchUpResponse], hold: Bool = false, group: Int64 = 12, user: Int64 = 20) {
        self.replies = replies; self.hold = hold; groupRevision = group; userRevision = user
    }

    func holdReactionRead() {
        holdMessages = true
    }

    func release() {
        messageWaiter?.resume(); messageWaiter = nil; holdMessages = false
        waiter?.resume(); waiter = nil; hold = false
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.url.path
        if path.contains("/mole/world") {
            return HTTPResponse(
                status: 200,
                headers: .init([]),
                body: Data(LocalBridgeBackendTests.shell(app: "DynamiteWebUi").utf8)
            )
        }
        if path.contains("get_self_user_status") {
            var me = GetSelfUserStatusResponse()
            me.userStatus.userID.id = "me"
            return try response(me)
        }
        if path.contains("list_messages") {
            if holdMessages {
                messagesHeld = true; await withCheckedContinuation { messageWaiter = $0 }
            }
            var result = ListMessagesResponse()
            result.messages = [Self.event(revision: 13).bodies[0].messagePosted.message]
            return try response(result)
        }
        if path.contains("paginated_world") {
            return try response(world())
        }
        if path.contains("catch_up_group") || path.contains("catch_up_user") {
            let from: Int64 = if path.contains("catch_up_group") {
                try CatchUpGroupRequest(serializedBytes: request.body ?? Data()).range.fromRevisionTimestamp
            } else {
                try CatchUpUserRequest(serializedBytes: request.body ?? Data()).range.fromRevisionTimestamp
            }
            froms.append(from)
            if hold {
                held = true; await withCheckedContinuation { waiter = $0 }
            }
            let next = replies.isEmpty ? Self.page(status: .completed) : replies.removeFirst()
            return try response(next)
        }
        return HTTPResponse(status: 200, headers: .init([]), body: Data([0x98, 0x06, 0x01]))
    }

    func stream(_ request: HTTPRequest) -> HTTPStream {
        let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        streams.append(continuation)
        return HTTPStream(status: 200, headers: .init([
            ("X-HTTP-Initial-Response", #"[[0,["c","fixture-session","",8,12,30000]]]"#)
        ]), body: body)
    }

    private func response(_ value: some SwiftProtobuf.Message) throws -> HTTPResponse {
        try HTTPResponse(status: 200, headers: .init([]), body: value.serializedData())
    }

    private func world() -> PaginatedWorldResponse {
        var response = PaginatedWorldResponse()
        response.userRevision.timestamp = userRevision
        var first = WorldItemFixture.item(groupID: WorldItemFixture.spaceGroupID("a"), roomName: "A")
        first.groupRevision.timestamp = groupRevision
        var second = WorldItemFixture.item(groupID: WorldItemFixture.spaceGroupID("b"), roomName: "B")
        second.groupRevision.timestamp = 10
        response.worldItems = [first, second]
        return response
    }

    static func page(status: CatchUpResponse.ResponseStatus, events: [Event] = []) -> CatchUpResponse {
        var response = CatchUpResponse()
        response.status = status; response.events = events
        return response
    }

    static func event(
        revision: Int64,
        group: String = "a",
        text: String = "Edited",
        deleted: Bool = false
    ) -> Event {
        var message = GChatBridgeCore.Message()
        message.id.messageID = "message-\(group)"
        message.id.parentID.topicID.topicID = "topic"
        message.id.parentID.topicID.groupID.spaceID.spaceID = group
        message.creator.userID.id = "peer"
        message.createTime = 1_700_000_000_000_000
        message.lastUpdateTime = message.createTime + revision
        message.textBody = text
        if deleted {
            message.deleteTime = message.lastUpdateTime
        }
        var event = Event()
        event.groupRevision.timestamp = revision
        event.type = .messageUpdated
        var body = Event.EventBody()
        body.eventType = .messageUpdated
        body.messagePosted.message = message
        event.bodies = [body]
        return event
    }
}
