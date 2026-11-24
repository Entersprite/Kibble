import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@Suite(.timeLimit(.minutes(1)))
struct SyncedDraftBackendTests {
    @Test func pagingRoundTripsTheAccountGroupAndTopicScopes() async throws {
        let transport = DraftTransport()
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        let room = ComposerDraftAddress(conversation: .init("space/a"))
        let thread = ComposerDraftAddress(conversation: room.conversation, thread: .init("topic"))

        let first = try await backend.syncedDrafts(at: nil, after: nil)
        let second = try await backend.syncedDrafts(at: nil, after: first.nextCursor)
        let roomPage = try await backend.syncedDrafts(at: room, after: nil)
        let threadPage = try await backend.syncedDrafts(at: thread, after: nil)
        #expect(first.drafts == roomPage.drafts && first.nextCursor == "next")
        #expect(second.drafts == threadPage.drafts && second.nextCursor == nil)
        #expect(roomPage.drafts.first?.id.address == room && threadPage.drafts.first?.id.address == thread)
        #expect(roomPage.drafts.first?.body.text == "Draft sample")
        #expect(roomPage.drafts.first?.modifiedAt == Date(timeIntervalSince1970: 1_700_000_000.5))
        #expect(roomPage.drafts.first?.changeToken == "changed-on-web")
        #expect(roomPage.drafts.first?.canRestore == true)
        #expect(threadPage.drafts.first?.canRestore == false)

        let requests = await transport.requests
        try #require(requests.count == 4)
        #expect(requests
            .allSatisfy { $0.scope.unsentType == 2 && $0.scope.hasListMode && $0.scope.listMode == 0 })
        #expect(requests[0].scope.groupID == GroupId() && !requests[0].scope.hasGroupOnly)
        #expect(requests[1].options.cursor == "next")
        #expect(requests[2].scope.groupID.spaceID.spaceID == "a" && requests[2].scope.groupOnly)
        #expect(requests[3].scope.topicID.groupID == requests[3].scope.groupID)
        #expect(requests[3].scope.topicID.topicID == "topic" && !requests[3].scope.hasGroupOnly)
        await backend.disconnect()
    }

    @Test(arguments: [DraftTransport.Reply.foreignThread, .scheduled, .duplicate])
    func draftScopeRejectsMismatchedOrDuplicateResults(reply: DraftTransport.Reply) async throws {
        let backend = LocalBridgeBackend(
            cookies: SearchBackendSupport.cookies,
            transport: DraftTransport(reply: reply)
        )
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        let room = ComposerDraftAddress(conversation: .init("space/a"))
        await #expect(throws: ChatError.self) { try await backend.syncedDrafts(at: room, after: nil) }
        await backend.disconnect()
    }
}

actor DraftTransport: HTTPTransport {
    enum Reply: Sendable { case valid, foreignThread, scheduled, duplicate }

    let base = ActionTransport(kind: .space)
    let reply: Reply
    private(set) var requests: [ListUnsentMessagesRequest] = []

    init(reply: Reply = .valid) {
        self.reply = reply
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url.lastPathComponent == "list_unsent_messages"
        else { return try await base.send(request) }
        #expect(request.method == .post)
        let list = try ListUnsentMessagesRequest(serializedBytes: request.body ?? Data())
        requests.append(list)
        var record = UnsentMessage()
        record.id.localID = "draft-1"
        record.id.groupID.spaceID.spaceID = "a"
        record.text = "Draft sample"
        record.unsentType = reply == .scheduled ? 1 : 2
        record.modifiedTime.seconds = 1_700_000_000
        record.modifiedTime.nanos = 500_000_000
        record.clientSyncValue = "changed-on-web"
        if list.scope.hasTopicID || list.options.hasCursor || reply == .foreignThread {
            record.id.topicID = "topic"
            record.annotations = [Annotation()]
        }
        var response = ListUnsentMessagesResponse()
        response.revision.timestamp = 10
        response.messages = reply == .duplicate ? [record, record] : [record]
        if !list.scope.hasGroupID, !list.options.hasCursor {
            response.nextCursor = "next"
        }
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }
}
