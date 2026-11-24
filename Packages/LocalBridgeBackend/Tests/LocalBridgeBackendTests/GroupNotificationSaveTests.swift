import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

private actor NotificationTransport: HTTPTransport {
    enum ReadBack: Equatable, Sendable { case matching, stale, wrongSpace, notJoined }

    private let base: ActionTransport
    private let group: GroupId
    private let kind: SharedAttributeCheckerGroupType
    private let readBack: ReadBack
    private let confirmationHold: SearchHold?
    private let heldRead: Int
    private(set) var writes: [UpdateGroupNotificationSettingsRequest] = []
    private(set) var reads = 0

    init(
        _ readBack: ReadBack, confirmationHold: SearchHold? = nil, heldRead: Int = 2,
        conversationKind: Conversation.Kind = .space
    ) {
        self.readBack = readBack
        self.confirmationHold = confirmationHold
        self.heldRead = heldRead
        base = ActionTransport(kind: conversationKind)
        group = conversationKind == .directMessage
            ? WorldItemFixture.dmGroupID("a") : WorldItemFixture.spaceGroupID("a")
        kind = switch conversationKind {
        case .directMessage: .oneToOneHumanDm
        case .groupDirectMessage: .immutableMembershipGroupDm
        default: .flatRoom
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.path.hasSuffix("/api/get_group") {
            reads += 1
            let target = try GetGroupRequest(serializedBytes: request.body ?? Data())
            #expect(target.groupID == group)
            var response = GetGroupResponse()
            response.group.groupID = readBack == .wrongSpace && reads == 2
                ? WorldItemFixture.spaceGroupID("other") : group
            response.group.attributeCheckerGroupType = kind
            response.membershipState = readBack == .notJoined ? .memberInvited : .memberJoined
            if readBack == .matching, let lastWrite = writes.last {
                response.group.groupReadState.notificationSettings = lastWrite.settings
            } else {
                response.group.groupReadState.notificationSettings.roomState = .notifyAll
                response.group.groupReadState.notificationSettings.muteSettings.state = .muted
            }
            if reads == heldRead {
                try await confirmationHold?.wait()
            }
            return try ok(response.serializedData())
        }
        if request.url.path.hasSuffix("/api/update_group_notification_settings") {
            let write = try UpdateGroupNotificationSettingsRequest(serializedBytes: request.body ?? Data())
            writes.append(write)
            if readBack == .matching {
                return ok(Data())
            }
            var response = UpdateGroupNotificationSettingsResponse()
            response.settings = write.settings
            return try ok(response.serializedData())
        }
        return try await base.send(request)
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }

    private func ok(_ data: Data) -> HTTPResponse {
        HTTPResponse(status: 200, headers: HTTPHeaders([]), body: data)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct GroupNotificationSaveTests {
    @Test(arguments: [Conversation.Kind.space, .directMessage, .groupDirectMessage])
    func timedMuteAndUnmutePreserveTheProviderLevel(_ kind: Conversation.Kind) async throws {
        let transport = NotificationTransport(.matching, conversationKind: kind)
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        let id = Conversation.ID(kind == .directMessage ? "dm/a" : "space/a")
        let seconds = Date.now.timeIntervalSince1970.rounded(.down) + 3600
        let end = Date(timeIntervalSince1970: seconds + 0.375)
        try await backend.setConversationMute(.until(end), in: id)
        try await backend.setConversationMute(.untilResumed, in: id)
        try await backend.setConversationMute(.off, in: id)
        let writes = await transport.writes
        try #require(writes.count == 3)
        #expect(writes.map(\.settings.roomState) == [.notifyAll, .notifyAll, .notifyAll])
        #expect(writes.map(\.settings.muteSettings.state) == [.muted, .muted, .unmuted])
        #expect(writes[0].settings.muteSettings.expiry.seconds == Int64(seconds))
        #expect(writes[0].settings.muteSettings.expiry.nanos == 375_000_000)
        #expect(!writes[1].settings.muteSettings.hasExpiry && !writes[2].settings.muteSettings.hasExpiry)
        await backend.disconnect()
    }

    @Test func aPastOrTooDistantEndTimeSendsNoMuteWrite() async throws {
        let transport = NotificationTransport(.matching)
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        for end in [Date.distantPast, .now.addingTimeInterval(121 * 86400)] {
            await #expect(throws: ChatError.self) {
                try await backend.setConversationMute(.until(end), in: Conversation.ID("space/a"))
            }
        }
        #expect(await transport.writes.isEmpty)
        await backend.disconnect()
    }

    @Test(arguments: [1, 2])
    func aNewerChannelUpdateFencesAHeldReadWithoutRetryingTheWrite(_ heldRead: Int) async throws {
        let hold = SearchHold()
        let transport = NotificationTransport(.matching, confirmationHold: hold, heldRead: heldRead)
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        let id = Conversation.ID("space/a")
        let save = Task { try await backend.setConversationMute(.untilResumed, in: id) }
        try await SearchBackendSupport.waitUntilEntered(hold)
        let change = ChannelEventBody(typeTag: 18, value: .object(["17": [[["a"]], [nil, 2]]]))
        let events = await backend.prepareChannelEvent(ChannelEvent(bodies: [change]))
        #expect(events == [.conversationNotificationSettingsChanged(
            conversationID: id, level: .less, muted: nil
        )])
        await hold.release()
        await #expect(throws: ChatError.self) { try await save.value }
        #expect(await transport.writes.count == heldRead - 1)
        await backend.disconnect()
    }

    @Test(arguments: [
        (NotificationLevel.always, GroupNotificationSettings.RoomNotificationState.notifyAll),
        (.lessWithNewThreads, .notifyMainConversation), (.less, .notifyLess), (.never, .notifyNever)
    ])
    func savesOneScopedWriteAndPublishesConfirmedReadback(
        level: NotificationLevel, wire: GroupNotificationSettings.RoomNotificationState
    ) async throws {
        let transport = NotificationTransport(.matching)
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        let id = Conversation.ID("space/a")
        try await backend.setNotificationSetting(level, for: id)

        let writes = await transport.writes
        #expect(writes.count == 1)
        let write = try #require(writes.first)
        #expect(write.groupID == WorldItemFixture.spaceGroupID("a"))
        #expect(write.settings.roomState == wire)
        #expect(write.settings.muteSettings.state == .unmuted)
        #expect(!write.settings.hasState && !write.settings.muteSettings.hasExpiry)
        #expect(await transport.reads == 2)

        await backend.disconnect()
        let expected = ChatEvent.conversationNotificationSettingsChanged(
            conversationID: id, level: level, muted: false
        )
        var found = false
        for await event in backend.events {
            if event == expected {
                found = true
                break
            }
            if case .connectionStateChanged(.disconnected(reason: nil, issue: nil)) = event {
                break
            }
        }
        #expect(found)
    }

    @Test(arguments: [NotificationTransport.ReadBack.stale, .wrongSpace, .notJoined])
    private func refusesUnconfirmedSettings(_ answer: NotificationTransport.ReadBack) async throws {
        let transport = NotificationTransport(answer)
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        await #expect(throws: ChatError.self) {
            try await backend.setNotificationSetting(.never, for: Conversation.ID("space/a"))
        }
        #expect(await transport.writes.count == (answer == .notJoined ? 0 : 1))
        #expect(await transport.reads == (answer == .notJoined ? 1 : 2))
        await backend.disconnect()
    }
}
