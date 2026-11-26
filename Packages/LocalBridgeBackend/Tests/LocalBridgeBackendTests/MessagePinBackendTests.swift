import ChatKit
import Foundation
import GChatBridgeCore
import SwiftProtobuf
import Testing
@testable import LocalBridgeBackend

private actor PinTransport: HTTPTransport {
    let base = ActionTransport(kind: .space)
    let allowed: Bool
    let invalidTarget: Bool
    let unconfirmed: Bool
    let hold: IgnoringHold?
    var pinned = true
    private(set) var mutations = 0
    private(set) var lists = 0

    init(
        allowed: Bool = true,
        invalidTarget: Bool = false,
        unconfirmed: Bool = false,
        hold: IgnoringHold? = nil
    ) {
        self.allowed = allowed; self.invalidTarget = invalidTarget
        self.unconfirmed = unconfirmed; self.hold = hold
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let data = request.body ?? Data()
        switch request.url.lastPathComponent {
        case "get_group":
            let input = try GetGroupRequest(serializedBytes: data)
            var result = GetGroupResponse()
            result.group.groupID = input.groupID; result.membershipState = .memberJoined
            return try ok(result)
        case "get_group_scoped_capabilities":
            let input = try GetGroupScopedCapabilitiesRequest(serializedBytes: data)
            var caps = GroupScopedCapabilities(); caps.id = input.membershipIds[0]
            caps.capabilities = [59]
            var fields = ProbeProtoWriter(); fields.bool(59, allowed)
            caps.permissions = try ManagementPermissions(serializedBytes: fields.data)
            var result = GetGroupScopedCapabilitiesResponse(); result.capabilities = [caps]
            return try ok(result)
        case "list_messages":
            lists += 1
            let input = try ListMessagesRequest(serializedBytes: data)
            #expect(input.parentID.topicID.groupID == WorldItemFixture.spaceGroupID("a"))
            #expect(input.parentID.topicID.topicID.isEmpty)
            #expect(input.pageSize == 100)
            #expect(input.filter.labels.map(\.labelType) == [2])
            #expect(input.filter.labelTimeAnchor == -1)
            if let hold {
                await hold.wait()
            }
            var result = ListMessagesResponse()
            result.groupRevision.timestamp = 1
            result.messages = pinned ? [message()] : []
            return try ok(result)
        case "get_message":
            let input = try GetMessageRequest(serializedBytes: data)
            #expect(input.messageID == message().id)
            var result = GetMessageResponse(); result.message = message()
            if invalidTarget {
                result.message.id.parentID.topicID.groupID = WorldItemFixture.spaceGroupID("other")
            }
            return try ok(result)
        case "apply_message_label", "remove_message_label":
            let input = try ApplyMessageLabelRequest(serializedBytes: data)
            #expect(input.messageID == message().id)
            #expect(input.label.labelType == 2 && input.label.hasCreateTime && input.label.createTime == 0)
            mutations += 1
            if !unconfirmed {
                pinned = request.url.lastPathComponent == "apply_message_label"
            }
            return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
        default: return try await base.send(request)
        }
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }

    private func message() -> GChatBridgeCore.Message {
        var value = GChatBridgeCore.Message()
        value.id = MessagePinRequests.address(
            group: WorldItemFixture.spaceGroupID("a"),
            topic: "old-topic",
            message: "old-pin"
        )
        value.messageType = .userMessage; value.creator.userID.id = "other"
        value.creator.name = "Alex"; value.textBody = "Outside the recent history window"
        value.createTime = 1_700_000_000_000_000
        return value
    }

    private func ok(_ message: some SwiftProtobuf.Message) throws -> HTTPResponse {
        try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: message.serializedData())
    }
}

private final class PinProbeSecrets: SecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) -> Data? {
        lock.withLock { values[account] }
    }

    func write(_ data: Data, account: String) {
        lock.withLock { values[account] = data }
    }

    func delete(account: String) {
        lock.withLock { values[account] = nil }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct MessagePinBackendTests {
    private let address = MessageAddress(
        conversation: .init("space/a"),
        thread: .init("old-topic"),
        message: .init("old-pin")
    )

    @Test func readsOldPinsAndConfirmsBothMutationDirectionsThroughTheRealAPIClient() async throws {
        let transport = PinTransport(); let backend = try await connected(transport)
        #expect(backend.capabilities.canReadMessagePins)
        let pins = try await backend.pinnedMessages(in: address.conversation)
        #expect(pins.messages.map(\.id.rawValue) == ["old-pin"])
        #expect(pins.members.first?.displayName == "Alex" && pins.canModify)
        #expect(try await backend.setMessagePinned(false, at: address).messages.isEmpty)
        #expect(try await backend.setMessagePinned(true, at: address).messages.count == 1)
        #expect(await transport.mutations == 2)
        await backend.disconnect()
    }

    @Test func anExplicitDenialOverridesLegacyPermissionAndNeverWrites() async throws {
        let transport = PinTransport(allowed: false); let backend = try await connected(transport)
        #expect(try await !backend.pinnedMessages(in: address.conversation).canModify)
        await #expect(throws: ChatError.self) { try await backend.setMessagePinned(false, at: address) }
        #expect(await transport.mutations == 0)
        await backend.disconnect()
    }

    @Test func aForeignOriginalCannotAuthorizePinning() async throws {
        let transport = PinTransport(invalidTarget: true); let backend = try await connected(transport)
        await #expect(throws: ChatError.self) { try await backend.setMessagePinned(false, at: address) }
        #expect(await transport.mutations == 0)
        await backend.disconnect()
    }

    @Test func anEmptyAcknowledgementIsNotEnoughWithoutConfirmedMembership() async throws {
        let transport = PinTransport(unconfirmed: true); let backend = try await connected(transport)
        await #expect(throws: ChatError.self) { try await backend.setMessagePinned(false, at: address) }
        #expect(await transport.mutations == 1)
        await backend.disconnect()
    }

    @Test func aCanceledReadCannotPublishAStalePinCollection() async throws {
        let hold = IgnoringHold(); let transport = PinTransport(hold: hold)
        let backend = try await connected(transport)
        let read = Task { try await backend.pinnedMessages(in: address.conversation) }
        try await SearchBackendSupport.waitUntilEntered(hold)
        read.cancel(); await hold.release()
        await #expect(throws: CancellationError.self) { try await read.value }
        await backend.disconnect()
    }

    @Test func disconnectFencesAnUncooperativeReadFromTheRetiredSession() async throws {
        let hold = IgnoringHold(); let transport = PinTransport(hold: hold)
        let backend = try await connected(transport)
        let read = Task { try await backend.pinnedMessages(in: address.conversation) }
        try await SearchBackendSupport.waitUntilEntered(hold)
        await backend.disconnect(); await hold.release()
        await #expect(throws: CancellationError.self) { try await read.value }
    }

    @Test func theLiveProbeOnlyReadsAndNeverReportsCredentialsOrMessageValues() async throws {
        let transport = PinTransport()
        let store = KeychainCredentialStore(storage: PinProbeSecrets(), account: "pins-test")
        try await store.store(StoredSession(
            credential: #require(SessionCookies(header: "SID=SECRET-PIN-PROBE-COOKIE")),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000), expiresAt: nil
        ))
        let report = await MessagePinProbeReport.run(
            store: store,
            expectedSelfID: .init("me"),
            transport: transport
        )
        #expect(report.contains("pins=1 mapped=1") && report.contains("originalMatches=true"))
        for secret in ["SECRET-PIN-PROBE-COOKIE", "old-pin", "Outside the recent history window", "Alex"] {
            #expect(!report.contains(secret))
        }
        #expect(await transport.mutations == 0)
        #expect(await transport.lists == 1)
    }

    private func connected(_ transport: PinTransport) async throws -> LocalBridgeBackend {
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect(); try await SearchBackendSupport.waitForSelf(backend)
        return backend
    }
}
