import ChatKit
import Foundation
import GChatBridgeCore
import SwiftProtobuf
import Testing
@testable import LocalBridgeBackend

actor MeetingDetailTransport: HTTPTransport {
    let base = ActionTransport()
    var items: [WorldItemLite]
    var holding = true
    var reject = false
    var mismatched = false
    var unsupported = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var requests = 0
    private(set) var active = 0
    private(set) var maximum = 0

    init(count: Int = 2) {
        items = (0 ..< count).map { index in
            var item = WorldItemFixture.item(
                groupID: WorldItemFixture.spaceGroupID("meeting-\(index)"),
                roomName: "Planning - occurrence \(index)",
                groupType: .meetingChat
            )
            item.groupRevision.timestamp = 1
            return item
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch request.url.lastPathComponent {
        case "paginated_world":
            var response = PaginatedWorldResponse(); response.worldItems = items
            response.userRevision.timestamp = 1
            return try ok(response)
        case "get_group":
            requests += 1; active += 1; maximum = max(maximum, active)
            defer { active -= 1 }
            if holding {
                await withCheckedContinuation { waiting.append($0) }
            }
            if reject {
                return HTTPResponse(status: 403, headers: HTTPHeaders([]), body: Data())
            }
            let input = try GetGroupRequest(serializedBytes: request.body ?? Data())
            var response = GetGroupResponse()
            response.group.groupID = mismatched ? WorldItemFixture.spaceGroupID("wrong") : input.groupID
            if !unsupported {
                let latest = input.groupID == WorldItemFixture.spaceGroupID("meeting-1")
                var integration = SpaceIntegrationPayload()
                integration.meetingChat.calendarEvent.eventID = latest ?
                    "parent_20261016T090000Z" : "parent_20261015T090000Z"
                integration.meetingChat.calendarEvent.title = "Planning"
                integration.meetingChat.calendarEvent.identityContext = "context"
                integration.meetingChat.calendarEvent.start.timestamp.seconds = latest ?
                    1_792_141_200 : 1_792_054_800
                response.group.spaceIntegrationPayloads = [integration]
            }
            return try ok(response)
        default: return try await base.send(request)
        }
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }

    func release() {
        holding = false
        let continuations = waiting; waiting = []
        for continuation in continuations {
            continuation.resume()
        }
    }

    func supplyWorldMetadata() {
        var integration = SpaceIntegrationPayload()
        integration.meetingChat.calendarEvent.eventID = "parent_20261015T090000Z"
        integration.meetingChat.calendarEvent.title = "Planning"
        integration.meetingChat.calendarEvent.identityContext = "context"
        integration.meetingChat.calendarEvent.start.timestamp.seconds = 1_792_054_800
        items[0].spaceIntegrationPayloads = [integration]
    }

    func setFailure(_ value: Bool) {
        reject = value
    }

    func mismatch() {
        mismatched = true
    }

    func setUnsupported() {
        unsupported = true
    }

    func removeAll() {
        items = []
    }

    func revise(metadataChanged: Bool = false) {
        for index in items.indices {
            items[index].groupRevision.timestamp += 1
            if metadataChanged {
                items[index].roomName += " revised"
            }
        }
    }

    func releaseOne() {
        waiting.removeFirst().resume()
    }

    private func ok(_ message: some SwiftProtobuf.Message) throws -> HTTPResponse {
        try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: message.serializedData())
    }
}

actor MeetingEventLog {
    var meetings: [Conversation.ID: MeetingOccurrence] = [:]
    var received: [ChatEvent] = []
    var loading: [Bool] = []
    var count: Int {
        received.count
    }

    var isEmpty: Bool {
        received.isEmpty
    }

    func record(_ event: ChatEvent) {
        if case let .meetingMetadataLoadingChanged(value) = event {
            loading.append(value)
        }
        if case let .meetingMetadataChanged(id, meeting) = event {
            received.append(event)
            meetings[id] = meeting
        }
    }
}
