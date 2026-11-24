import ChatKit
import Foundation
import GChatBridgeCore
import SwiftProtobuf
import Testing
@testable import LocalBridgeBackend

@Suite(.timeLimit(.minutes(1)))
struct SyncedDraftWriteTests {
    private let address = ComposerDraftAddress(conversation: .init("space/a"), thread: .init("topic"))

    @Test func savesEditsAndClearsOnlyTheCurrentDraftVersion() async throws {
        let transport = DraftWriteTransport()
        let backend = try await connected(transport)
        let quote = MessageQuote(message: ChatKit.Message(
            id: .init("quote"), conversationID: address.conversation, threadID: .init("topic"),
            sender: .init("peer"), text: "Quoted", createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        let createdResult = try await apply(
            to: backend, body: ComposedMessage(text: "Original", content: MessageContent(quote: quote))
        )
        let created = try #require(createdResult.current)
        #expect(createdResult.applied)
        #expect(created.body.content?.quote?.id == quote.id)
        let editedResult = try await apply(
            to: backend,
            previous: created,
            body: ComposedMessage(text: "Edited")
        )
        let edited = try #require(editedResult.current)
        #expect(editedResult.applied && edited.id == created.id && edited.changeToken != created.changeToken)
        #expect(edited.body.content?.quote == nil)

        let staleEdit = try await apply(to: backend, previous: created, body: ComposedMessage(text: "Stale"))
        let staleClear = try await apply(to: backend, previous: created, body: nil)
        #expect(staleEdit == SyncedDraftWriteResult(applied: false, current: edited))
        #expect(staleClear == staleEdit)
        let cleared = try await apply(to: backend, previous: edited, body: nil)
        #expect(cleared == SyncedDraftWriteResult(applied: true, current: nil))
        #expect(try await apply(to: backend, previous: edited, body: nil) == cleared)
        #expect(await transport.writes == [
            "create_unsent_message", "update_unsent_message", "delete_unsent_message"
        ])
        await backend.disconnect()
    }

    @Test func duplicateCreatePreservesTheOtherClientsDraft() async throws {
        let transport = DraftWriteTransport(behavior: .createConflict)
        let backend = try await connected(transport)
        let result = try await apply(to: backend, body: ComposedMessage(text: "Local draft"))
        #expect(!result.applied && result.current?.body.text == "Other device")
        #expect(await transport.writes == ["create_unsent_message"])
        await backend.disconnect()
    }

    @Test func unconfirmedMutationIsNeverReplayed() async throws {
        let transport = DraftWriteTransport(behavior: .unexpectedSaveEcho)
        let backend = try await connected(transport)
        await #expect(throws: ChatError.self) {
            try await apply(to: backend, body: ComposedMessage(text: "Local draft"))
        }
        #expect(await transport.writes == ["create_unsent_message"])
        await backend.disconnect()
    }

    @Test func twoWritesForTheSameComposerCannotOverlap() async throws {
        let hold = SearchHold()
        let transport = DraftWriteTransport(createHold: hold)
        let backend = try await connected(transport)
        async let pending = apply(to: backend, body: ComposedMessage(text: "First draft"))
        try await SearchBackendSupport.waitUntilEntered(hold)
        await #expect(throws: ChatError.self) {
            try await apply(to: backend, body: ComposedMessage(text: "Second draft"))
        }
        await hold.release()
        let saved = try await pending
        #expect(saved.applied && saved.current?.body.text == "First draft")
        #expect(await transport.writes == ["create_unsent_message"])
        await backend.disconnect()
    }

    @Test func schedulesTheSameDraftOnceAndRecoversALostResponse() async throws {
        let transport = DraftWriteTransport(behavior: .lostConversionReply)
        let backend = try await connected(transport)
        let saved = try await apply(to: backend, body: ComposedMessage(text: "Original"))
        let original = try #require(saved.current)
        let edited = try await apply(
            to: backend,
            previous: original,
            body: ComposedMessage(text: "Edited elsewhere")
        )
        let baseline = try #require(edited.current)
        let delivery = Date(timeIntervalSince1970: 2_500_000_000)
        let submitted = ComposedMessage(text: "Final scheduled text")

        await #expect(throws: ChatError.self) {
            try await backend.scheduleSavedDraft(original, body: submitted, at: delivery)
        }
        #expect(try await backend.syncedDrafts(at: address, after: nil).drafts == [baseline])
        #expect(try await backend.scheduledMessages(after: nil).messages.isEmpty)

        let item = try await backend.scheduleSavedDraft(baseline, body: submitted, at: delivery)
        #expect(item.id.queueID == baseline.id.record && item.id.thread == address.thread)
        #expect(item.body == submitted && item.deliveryTime == delivery)
        #expect(try await backend.syncedDrafts(at: address, after: nil).drafts.isEmpty)
        #expect(try await backend.scheduledMessages(after: nil).messages == [item])
        await #expect(throws: ChatError.self) {
            try await backend.scheduleSavedDraft(baseline, body: submitted, at: delivery)
        }
        #expect(await transport.writes == [
            "create_unsent_message",
            "update_unsent_message",
            "update_unsent_message"
        ])
        await backend.disconnect()
    }

    @Test func postsOnceWhenTheDraftIsStaleAndConsumesOnlyTheCurrentVersion() async throws {
        let transport = DraftWriteTransport()
        let backend = try await connected(transport)
        let saved = try await apply(to: backend, body: ComposedMessage(text: "Original"))
        let original = try #require(saved.current)
        let edited = try await apply(
            to: backend,
            previous: original,
            body: ComposedMessage(text: "Other edit")
        )
        let current = try #require(edited.current)

        #expect(try await !backend.send(command("Local send", id: "local-send"), consuming: original))
        #expect(try await backend.syncedDrafts(at: address, after: nil).drafts == [current])
        let attachment = ChatKit.Attachment(
            id: "fixture-token",
            name: "fixture.txt",
            contentType: "text/plain"
        )
        let withAttachment = ChatCommand.sendMessage(
            conversationID: address.conversation, threadID: address.thread, text: "Other edit",
            localID: "next-send", attachments: [attachment]
        )
        #expect(try await backend.send(withAttachment, consuming: current))
        #expect(try await backend.syncedDrafts(at: address, after: nil).drafts.isEmpty)
        let posts = await transport.posts
        #expect(posts.map(\.localID) == ["local-send", "next-send"])
        #expect(posts.map(\.hasDraft) == [false, true])
        #expect(posts.map(\.attachmentToken) == [nil, attachment.id])
        #expect(await !transport.writes.contains("delete_unsent_message"))
        await backend.disconnect()
    }

    @Test func aLostDraftReadBackLeavesTheAcceptedPostAccepted() async throws {
        let transport = DraftWriteTransport(behavior: .lostReadAfterPost)
        let backend = try await connected(transport)
        let saved = try await apply(to: backend, body: ComposedMessage(text: "Original"))
        let original = try #require(saved.current)
        #expect(try await !backend.send(command("Original", id: "one-send"), consuming: original))
        let posts = await transport.posts
        #expect(posts.count == 1 && posts.first?.hasDraft == true)
        await backend.disconnect()
    }

    private func command(_ text: String, id: String) -> ChatCommand {
        .sendMessage(conversationID: address.conversation, threadID: address.thread, text: text, localID: id)
    }

    private func connected(_ transport: DraftWriteTransport) async throws -> LocalBridgeBackend {
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        return backend
    }

    private func apply(
        to backend: LocalBridgeBackend, previous: SyncedDraft? = nil, body: ComposedMessage?
    ) async throws -> SyncedDraftWriteResult {
        try await backend.writeSyncedDraft(
            SyncedDraftChange(address: address, previous: previous, body: body),
            operationID: ClientOperationID.make()
        )
    }
}

private actor DraftWriteTransport: HTTPTransport {
    enum Behavior { case normal, createConflict, unexpectedSaveEcho, lostConversionReply, lostReadAfterPost }

    struct Post {
        let localID: String
        let hasDraft: Bool
        let attachmentToken: String?
    }

    let base = ActionTransport(kind: .space)
    let behavior: Behavior
    let createHold: SearchHold?
    private var record: UnsentMessage?
    private(set) var writes: [String] = []
    private(set) var posts: [Post] = []

    init(behavior: Behavior = .normal, createHold: SearchHold? = nil) {
        self.behavior = behavior
        self.createHold = createHold
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let operation = request.url.lastPathComponent
        let body = request.body ?? Data()
        switch operation {
        case "list_unsent_messages":
            if behavior == .lostReadAfterPost, !posts.isEmpty {
                return HTTPResponse(status: 503, headers: HTTPHeaders([]), body: Data())
            }
            let list = try ListUnsentMessagesRequest(serializedBytes: body)
            var response = ListUnsentMessagesResponse()
            response.revision.timestamp = 10
            if let record, record.unsentType == list.scope.unsentType {
                response.messages = [record]
            }
            return try ok(response)
        case "create_unsent_message":
            writes.append(operation)
            if writes.count == 1, let createHold {
                try await createHold.wait()
            }
            return try create(CreateUnsentMessageRequest(serializedBytes: body).message)
        case "update_unsent_message":
            writes.append(operation)
            return try update(UpdateUnsentMessageRequest(serializedBytes: body))
        case "delete_unsent_message":
            writes.append(operation)
            let delete = try DeleteUnsentMessageRequest(serializedBytes: body)
            #expect(delete.id == record?.id)
            record = nil
            // The caller verifies the delete even when the response is lost.
            return HTTPResponse(status: 503, headers: HTTPHeaders([]), body: Data())
        case "create_message":
            return try post(CreateMessageRequest(serializedBytes: body))
        default:
            return try await base.send(request)
        }
    }

    private func post(_ message: CreateMessageRequest) throws -> HTTPResponse {
        let hasDraft = message.messageInfo.hasUnsentMessageID
        let upload = message.annotations.first { $0.type == .uploadMetadata }
        posts.append(Post(
            localID: message.localID, hasDraft: hasDraft,
            attachmentToken: upload?.uploadMetadata.attachmentToken
        ))
        if hasDraft {
            #expect(message.messageInfo.unsentMessageID == record?.id)
            #expect(message.parentID.topicID.topicID == message.messageInfo.unsentMessageID.topicID)
            record = nil
        }
        var response = CreateMessageResponse()
        response.message.id.parentID = message.parentID
        response.message.id.messageID = "provider-message"
        response.message.localID = message.localID
        return try ok(response)
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }

    private func create(_ message: UnsentMessage) throws -> HTTPResponse {
        var saved = message
        #expect(message.unsentType == 2 && !message.hasDelivery)
        #expect(message.id.groupID.spaceID.spaceID == "a" && message.id.topicID == "topic")
        #expect(message.id.localID.count == 11)
        #expect(UUID(uuidString: message.clientSyncValue)?.uuidString == message.clientSyncValue)
        if behavior == .createConflict {
            saved.id.localID = "web-draft"
            saved.text = "Other device"
            saved.clientSyncValue = "web-version"
            record = saved
            return HTTPResponse(status: 409, headers: HTTPHeaders([]), body: Data())
        }
        if behavior == .unexpectedSaveEcho {
            saved.clientSyncValue = "different-version"
        }
        record = saved
        return try sparseReply()
    }

    private func update(_ update: UpdateUnsentMessageRequest) throws -> HTTPResponse {
        let current = try #require(record)
        #expect(update.message.id == current.id)
        if update.message.unsentType == 1 {
            #expect(current.unsentType == 2)
            #expect(update.updateMask.wholeFields == [4, 5, 6, 7])
            #expect(update.updateMask.nestedFields.first?.fieldNumber == 8)
            record = update.message
            if behavior == .lostConversionReply {
                return HTTPResponse(status: 503, headers: HTTPHeaders([]), body: Data())
            }
            return try sparseReply()
        }
        #expect(!update.message.hasUnsentType && !update.message.hasDelivery)
        #expect(!update.message.hasReference)
        #expect(update.updateMask.wholeFields == [4, 5, 6, 9] && !update.updateMask.inverted)
        #expect(update.message.clientSyncValue != current.clientSyncValue)
        record = update.message
        record?.unsentType = 2
        return try sparseReply()
    }

    private func sparseReply() throws -> HTTPResponse {
        var response = WriteUnsentMessageResponse()
        response.revision.timestamp = 11
        return try ok(response)
    }

    private func ok(_ message: some SwiftProtobuf.Message) throws -> HTTPResponse {
        try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: message.serializedBytes())
    }
}
