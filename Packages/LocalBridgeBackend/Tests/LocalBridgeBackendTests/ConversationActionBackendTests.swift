import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

actor ActionTransport: HTTPTransport {
    struct NoStream: Error {}
    var item: WorldItemLite
    let reject: Bool
    let existing: Bool
    let requiresNativeAuthentication: Bool
    private(set) var requests: [HTTPRequest] = []

    init(
        kind: Conversation.Kind = .directMessage,
        reject: Bool = false,
        existing: Bool = true,
        requiresNativeAuthentication: Bool = false
    ) {
        self.reject = reject
        self.existing = existing
        self.requiresNativeAuthentication = requiresNativeAuthentication
        item = WorldItemFixture.item(
            groupID: kind == .space ? WorldItemFixture.spaceGroupID("a") : WorldItemFixture.dmGroupID("a"),
            dmMembers: ["me", "other"],
            groupType: kind == .space ? .flatRoom : kind == .groupDirectMessage ?
                .immutableMembershipGroupDm :
                .oneToOneHumanDm,
            lastReadMicros: 1_790_000_000_000_100, newestMessageMicros: 1_790_000_000_000_100
        )
        item.sortTimestamp = 1_790_000_000_000_200
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        let path = request.url.path
        if path.contains("/mole/world") {
            return SearchFixtures.fullShell()
        }
        if path.contains("/api/get_self_user_status") {
            var response = GetSelfUserStatusResponse()
            response.userStatus.userID.id = "me"
            return try ok(response.serializedData())
        }
        if path.contains("/api/paginated_world") {
            var response = PaginatedWorldResponse()
            response.worldItems = existing ? [item] : []
            response.userRevision.timestamp = 1
            return try ok(response.serializedData())
        }
        if path.contains("batchexecute") {
            let rpc = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "rpcids" }?.value ?? ""
            let code = rpc == "NyBsFc" ? 16 : (reject ? 7 : nil)
            return try ok(SearchFixtures.answerBody(inner: [], errorCode: code, rpc: rpc))
        }
        if reject {
            return ok(Data())
        }
        if let response = try nativeResponse(request) {
            return response
        }
        if path.contains("/api/block_entity") {
            var response = BlockEntityResponse()
            response.readState.blocked = true
            return try ok(response.serializedData())
        }
        if path.contains("/api/remove_memberships") {
            let input = try RemoveMembershipsRequest(serializedBytes: request.body ?? Data())
            var result = RemoveMembershipResult()
            result.memberID = input.memberIds[0]
            var response = RemoveMembershipsResponse()
            response.results = [result]
            return try ok(response.serializedData())
        }
        if path.contains("/api/mark_group_readstate") {
            var response = MarkGroupReadstateResponse()
            response.readState.lastReadTime = item.sortTimestamp + 1
            return try ok(response.serializedData())
        }
        return ok(Data())
    }

    private func nativeResponse(_ request: HTTPRequest) throws -> HTTPResponse? {
        if request.url.path.contains("/api/set_mark_as_unread_timestamp") {
            if requiresNativeAuthentication, request.headers["x-framework-xsrf-token"] == nil {
                return HTTPResponse(status: 401, headers: HTTPHeaders([]), body: Data())
            }
            let input = try SetMarkAsUnreadTimestampRequest(serializedBytes: request.body ?? Data())
            item.readState.markAsUnreadTimestampUsec = input.unreadTimestamp
            return ok(Data([0x0A, 0x00]))
        }
        if request.url.path.contains("/api/create_dm") {
            var response = CreateDmResponse()
            response.dm.groupID = item.groupID
            return try ok(response.serializedData())
        }
        if request.url.path.contains("/api/hide_group") {
            let input = try HideGroupRequest(serializedBytes: request.body ?? Data())
            item.readState.visibleInWorldView = !input.hide
            var response = HideGroupResponse()
            response.readState.hideTimestamp = item.sortTimestamp
            return try ok(response.serializedData())
        }
        return nil
    }

    func blockForTest() {
        item.readState.blocked = true
    }

    func hideForTest() {
        item.readState.visibleInWorldView = false
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }

    private func ok(_ data: Data) -> HTTPResponse {
        HTTPResponse(
            status: 200,
            headers: HTTPHeaders([]),
            body: data
        )
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ConversationActionBackendTests {
    private func connected(
        _ transport: ActionTransport, cookies: SessionCookies = SearchBackendSupport.cookies
    ) async throws -> LocalBridgeBackend {
        let backend = LocalBridgeBackend(cookies: cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        return backend
    }

    @Test func unreadUsesTheEarlierServerTimestampAndReadClearsItFirst() async throws {
        let transport = ActionTransport()
        let backend = try await connected(transport)
        let id = Conversation.ID("dm/a")
        try await backend.send(.conversationAction(conversationID: id, action: .markUnread))
        try await backend.send(.markRead(conversationID: id, upTo: Microseconds.date(1_790_000_000_000_200)))
        let marks = await transport.requests
            .filter { $0.url.path.contains("/api/set_mark_as_unread_timestamp") }
        #expect(marks.count == 2)
        #expect(try SetMarkAsUnreadTimestampRequest(serializedBytes: marks[0].body ?? Data()).unreadTimestamp
            == 1_790_000_000_000_099)
        #expect(try SetMarkAsUnreadTimestampRequest(serializedBytes: marks[1].body ?? Data())
            .unreadTimestamp == 0)
        let requests = await transport.requests
        #expect(requests.last { $0.url.path.contains("/api/mark_group_readstate") } != nil)
        await backend.disconnect()
    }

    @Test func deletingUsesTheServersCutoff() async throws {
        let transport = ActionTransport()
        let backend = try await connected(transport)
        try await backend.send(.conversationAction(conversationID: Conversation.ID("dm/a"), action: .delete))
        let batch = try #require(await transport.requests.last { $0.url.path.contains("batchexecute") })
        #expect(try SearchFixtures.innerPayload(of: batch)[1] as? Int64 == 1_790_000_000_000_200)
        await backend.disconnect()
    }

    @Test(arguments: [Conversation.Kind.directMessage, .groupDirectMessage, .space])
    func blockingTargetsThePersonOnlyForADirectMessage(_ kind: Conversation.Kind) async throws {
        let transport = ActionTransport(kind: kind)
        let backend = try await connected(transport)
        let id = Conversation.ID(kind == .space ? "space/a" : "dm/a")
        try await backend.send(.conversationAction(conversationID: id, action: .block))
        let request = try #require(await transport.requests
            .last { $0.url.path.contains("/api/block_entity") })
        let decoded = try BlockEntityRequest(serializedBytes: request.body ?? Data())
        if kind == .directMessage {
            #expect(decoded.userID.id == "other")
        } else {
            #expect(await decoded.groupID == (transport.item).groupID)
        }
        #expect(decoded.blocked && !decoded.reported)
        await backend.disconnect()
    }

    @Test(arguments: [Conversation.Kind.groupDirectMessage, .space])
    func leavingRemovesOnlyTheCurrentMember(_ kind: Conversation.Kind) async throws {
        let transport = ActionTransport(kind: kind)
        let backend = try await connected(transport)
        let id = Conversation.ID(kind == .space ? "space/a" : "dm/a")
        try await backend.send(.conversationAction(conversationID: id, action: .leave))
        let request = try #require(await transport.requests
            .last { $0.url.path.contains("/api/remove_memberships") })
        let decoded = try RemoveMembershipsRequest(serializedBytes: request.body ?? Data())
        #expect(decoded.memberIds.map(\.userID.id) == ["me"])
        await backend.disconnect()
    }

    @Test(arguments: [ConversationAction.markUnread, .hide, .block, .delete])
    func unconfirmedResponsesThrowInsteadOfPretendingToSucceed(_ action: ConversationAction) async throws {
        let transport = ActionTransport(reject: true)
        let backend = try await connected(transport)
        await #expect(throws: (any Error).self) {
            try await backend.send(.conversationAction(
                conversationID: Conversation.ID("dm/a"),
                action: action
            ))
        }
        await backend.disconnect()
    }
}

extension ConversationActionBackendTests {
    @Test func aStaleWorldCannotRestoreTheAcceptedDeletionCutoff() async throws {
        let transport = ActionTransport()
        let backend = try await connected(transport)
        let id = Conversation.ID("dm/a")
        try await backend.send(.conversationAction(conversationID: id, action: .delete))
        let conversations = try await backend.loadConversations()
        #expect(conversations.isEmpty)
        let reopened = try await backend.openDirectConversation(with: ChatKit.Member.ID("other"))
        #expect(reopened.historyClearedBefore == Microseconds.date(1_790_000_000_000_200))
        var old = ChatKit.Message(
            id: ChatKit.Message.ID("old"),
            conversationID: id,
            threadID: MessageThread.ID("t"),
            sender: ChatKit.Member.ID("other"),
            text: "old",
            createdAt: Microseconds.date(1_790_000_000_000_100)
        )
        let filtered = await backend.retainingUnclearedHistory([old], in: id)
        #expect(filtered.isEmpty)
        old.createdAt = Microseconds.date(1_790_000_000_000_300)
        #expect(await backend.retainingUnclearedHistory([old], in: id).count == 1)
        await backend.disconnect()
    }
}

extension ConversationActionBackendTests {
    @Test(arguments: [false, true])
    func openingAPersonRestoresTheirDMWithoutRestoringDeletedHistory(_ existing: Bool) async throws {
        let transport = ActionTransport(existing: existing)
        await transport.hideForTest()
        let backend = try await connected(transport)
        let id = Conversation.ID("dm/a")
        await backend.rememberClearHistoryForTest(id, through: 1_790_000_000_000_200)
        let conversation = try await (backend as any ChatBackend)
            .openDirectConversation(with: ChatKit.Member.ID("other"))
        #expect(conversation.id == id)
        #expect(conversation.historyClearedBefore == Microseconds.date(1_790_000_000_000_200))
        let requests = await transport.requests
        let hide = try #require(requests.last { $0.url.path.contains("/api/hide_group") })
        #expect(try HideGroupRequest(serializedBytes: hide.body ?? Data()).hide == false)
        let create = requests.last { $0.url.path.contains("/api/create_dm") }
        #expect((create != nil) == !existing)
        if let create {
            let request = try CreateDmRequest(serializedBytes: create.body ?? Data())
            #expect(request.members.map(\.id) == ["other"])
            #expect(request.invitees.map(\.userID.id) == ["other"])
            #expect(!request.hasRetentionSettings)
        }
        await backend.disconnect()
    }
}

private extension LocalBridgeBackend {
    func rememberClearHistoryForTest(_ id: Conversation.ID, through cutoff: Int64) {
        historyCutoffs[id] = cutoff
        hiddenConversations.insert(id)
    }
}

extension ConversationActionBackendTests {
    @Test func openingABlockedPersonDoesNotUnblockOrCreateADuplicate() async throws {
        let transport = ActionTransport()
        await transport.blockForTest()
        let backend = try await connected(transport)
        await #expect(throws: ChatError.self) {
            try await backend.openDirectConversation(with: ChatKit.Member.ID("other"))
        }
        #expect(await transport.requests.allSatisfy {
            !$0.url.path.contains("/api/create_dm") && !$0.url.path.contains("/api/hide_group")
        })
        await backend.disconnect()
    }

    @Test(arguments: [false, true])
    func anUnconfirmedOpenIsRefused(_ existing: Bool) async throws {
        let transport = ActionTransport(reject: true, existing: existing)
        let backend = try await connected(transport)
        await #expect(throws: ChatError.self) {
            try await backend.openDirectConversation(with: ChatKit.Member.ID("other"))
        }
        await backend.disconnect()
    }
}

extension ConversationActionBackendTests {
    @Test(arguments: [ConversationAction.hide, .delete])
    func acceptedRemovalSurvivesStaleWorldUntilNewMainActivity(_ action: ConversationAction) async throws {
        let transport = ActionTransport()
        let backend = try await connected(transport)
        let id = Conversation.ID("dm/a")
        try await backend.send(.conversationAction(conversationID: id, action: action))
        await transport.simulateStaleVisibilityForTest()
        #expect(try await backend.loadConversations().isEmpty)
        await transport.simulateReplyForTest()
        #expect(try await backend.loadConversations().isEmpty)
        await transport.simulateNewMainForTest()
        #expect(try await backend.loadConversations().map(\.id) == [id])
        await backend.disconnect()
    }

    @Test func rpcRefusalKeepsTheServiceCodeForDiagnostics() async throws {
        let transport = ActionTransport(reject: true)
        let backend = try await connected(transport)
        let observations = ConversationObservationLog()
        await backend.observeConversationActions { observations.append($0) }
        await #expect(throws: ChatError.self) {
            try await backend.send(.conversationAction(
                conversationID: Conversation.ID("dm/a"),
                action: .delete
            ))
        }
        #expect(observations.values == [ConversationActionObservation(
            rpc: "azPJGe", status: 200, serviceCode: 7, outcome: "serviceFailure", hasSessionProof: false
        )])
        await backend.disconnect()
    }
}

private final class ConversationObservationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ConversationActionObservation] = []
    func append(_ value: ConversationActionObservation) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(value)
    }

    var values: [ConversationActionObservation] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

private extension ActionTransport {
    func simulateStaleVisibilityForTest() {
        item.readState.visibleInWorldView = true
    }

    func simulateReplyForTest() {
        item.sortTimestamp += 1000
    }

    func simulateNewMainForTest() {
        item.readState.lastHeadMessageCreateTimeUsec = item.sortTimestamp + 1000
    }
}

extension ConversationActionBackendTests {
    @Test func unreadAndItsClearUseTheAuthenticatedNativeAPI() async throws {
        let transport = ActionTransport(requiresNativeAuthentication: true)
        let backend = try await connected(transport)
        let id = Conversation.ID("dm/a")
        try await backend.send(.conversationAction(conversationID: id, action: .markUnread))
        try await backend.send(.markRead(conversationID: id, upTo: Microseconds.date(1_790_000_000_000_200)))
        let requests = await transport.requests.filter {
            $0.url.path.contains("/api/set_mark_as_unread_timestamp")
        }
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.headers["x-framework-xsrf-token"] != nil)
            #expect(request.headers["Cookie"] != nil)
            let input = try SetMarkAsUnreadTimestampRequest(serializedBytes: request.body ?? Data())
            #expect(input.hasRequestHeader)
            #expect(input.groupID == WorldItemFixture.dmGroupID("a"))
        }
        #expect(await transport.requests.allSatisfy { !$0.url.path.contains("batchexecute") })
        await backend.disconnect()
    }
}
