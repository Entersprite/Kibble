import ChatKit
import Foundation
import GChatBridgeCore
import SwiftProtobuf
import Testing
@testable import LocalBridgeBackend

@Suite(.timeLimit(.minutes(1)))
struct ScheduledMessageBackendTests {
    @Test func confirmsTheExactScheduledResourceAndWritesEachChangeOnce() async throws {
        let transport = ScheduledMessageTransport()
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        let time = Date(timeIntervalSince1970: 2_500_000_000)
        let thread = MessageThread.ID("topic")
        let quote = MessageQuote(message: ChatKit.Message(
            id: .init("quote"), conversationID: .init("space/a"), threadID: thread, sender: .init("peer"),
            text: "Original", createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        let body = ComposedMessage(text: "Scheduled sample", content: MessageContent(
            formatting: [.init(style: "bold", start: 0, length: 9)], quote: quote
        ))
        let message = try await backend.scheduleMessage(
            in: .init("space/a"), thread: thread, body: body, at: time
        )
        let queueID = message.id.queueID
        #expect(queueID.count == 11 && !queueID.contains("="))
        let standardBase64 = queueID
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        #expect(Data(base64Encoded: standardBase64 + "=")?.count == 8)
        #expect(!queueID.contains("+") && !queueID.contains("/"))
        #expect(message.id.thread == thread)
        #expect(message.body.content?.formatting == body.content?.formatting)
        let forged = ScheduledMessageAddress(
            conversation: message.id.conversation,
            thread: nil,
            queueID: "draft"
        )
        await #expect(throws: ChatError.self) { try await backend.cancelScheduledMessage(forged) }

        let edited = try await backend.editScheduledMessage(
            message.id,
            body: ComposedMessage(text: "Edited sample")
        )
        #expect(edited.body.text == "Edited sample" && edited.deliveryTime == time)
        #expect(edited.body.content?.quote?.id == quote.id)
        let moved = try await backend.rescheduleMessage(message.id, at: time.addingTimeInterval(3600))
        #expect(moved.body == edited.body && moved.deliveryTime == time.addingTimeInterval(3600))
        #expect(try await backend.scheduledMessages(after: nil).messages == [moved])
        try await backend.cancelScheduledMessage(message.id)
        #expect(try await backend.scheduledMessages(after: nil).messages.isEmpty)
        #expect(await transport.writes == [
            "create_unsent_message",
            "update_unsent_message",
            "update_unsent_message",
            "delete_unsent_message"
        ])
        await backend.disconnect()
    }

    @Test func sendNowWritesOnlyTheOriginalReplyAndRejectsAStaleAddress() async throws {
        var record = UnsentMessage()
        record.id.localID = "gchat%1234"
        record.id.groupID.spaceID.spaceID = "a"
        record.id.topicID = "topic"
        record.text = "Scheduled reply"
        record.unsentType = 1
        record.delivery.scheduledTime.seconds = 2_500_000_000
        let transport = ScheduledMessageTransport(queued: record)
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        let page = try await backend.scheduledMessages(after: nil)
        let address = try #require(page.messages.first?.id)

        try await backend.sendScheduledMessageNow(address)
        #expect(try await backend.scheduledMessages(after: nil).messages.isEmpty)
        await #expect(throws: ChatError.self) { try await backend.sendScheduledMessageNow(address) }
        #expect(await transport.writes == ["create_message"])
        await backend.disconnect()
    }

    @Test func aQueuedFileKeepsItsAnnotationWhenTheCaptionChangesAndSendsNow() async throws {
        let record = scheduledUpload()
        let transport = ScheduledMessageTransport(queued: record)
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        let page = try await backend.scheduledMessages(after: nil)
        let queued = try #require(page.messages.first)
        #expect(queued.attachmentNames == ["Design.pdf"] && queued.canEditBody)
        let json = try JSONEncoder().encode(queued)
        #expect(!String(decoding: json, as: UTF8.self).contains("fixture-upload-token"))
        #expect(try JSONDecoder().decode(ScheduledMessage.self, from: json) == queued)

        let edited = try await backend.editScheduledMessage(queued.id, body: ComposedMessage(text: ""))
        #expect(edited.body.text.isEmpty && edited.attachmentNames == queued.attachmentNames)
        #expect(edited.deliveryTime == queued.deliveryTime)
        #expect(await transport.editedAnnotations == record.annotations)
        try await backend.sendScheduledMessageNow(queued.id)
        #expect(try await backend.scheduledMessages(after: nil).messages.isEmpty)
        #expect(await transport.writes == ["update_unsent_message", "create_message"])
        await backend.disconnect()
    }

    @Test func createsOneFileOnlyScheduleWithBothUploadAnnotations() async throws {
        let transport = ScheduledMessageTransport()
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        let address = ComposerDraftAddress(conversation: .init("space/a"), thread: .init("topic"))
        let files = ["one.pdf", "two.pdf"].map { name in
            ChatKit.Attachment(id: "fixture-\(name)", name: name, contentType: "application/pdf")
        }
        let message = try await backend.scheduleWithAttachments(
            in: address, body: ComposedMessage(text: ""), attachments: files,
            at: Date(timeIntervalSince1970: 2_500_000_000), converting: nil
        )
        #expect(message.body.text.isEmpty && message.attachmentNames == files.map(\.name))
        let annotations = await transport.createdAnnotations
        #expect(annotations.map(\.uploadMetadata.attachmentToken) == files.map(\.id))
        #expect(await transport.writes == ["create_unsent_message"])
        await backend.disconnect()
    }

    @Test func anAnchoredUploadStaysReadOnlyAndAMissingUploadCannotConfirmAnEdit() async throws {
        var anchored = scheduledUpload()
        anchored.annotations[0].length = 1
        let preview = try ScheduledMessageMapping.message(anchored)
        #expect(preview.attachmentNames == ["Design.pdf"] && !preview.canEditBody)

        let transport = ScheduledMessageTransport(queued: scheduledUpload(), dropsUploadsOnEdit: true)
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        let page = try await backend.scheduledMessages(after: nil)
        let address = try #require(page.messages.first?.id)
        await #expect(throws: ChatError.self) {
            try await backend.editScheduledMessage(address, body: ComposedMessage(text: "Updated caption"))
        }
        #expect(await transport.writes == ["update_unsent_message"])
        await backend.disconnect()
    }

    private func scheduledUpload() -> UnsentMessage {
        var upload = UploadMetadata()
        upload.attachmentToken = "fixture-upload-token"
        upload.contentName = "Design.pdf"
        upload.contentType = "application/pdf"
        var record = UnsentMessage()
        record.id.localID = "queued-upload"
        record.id.groupID.spaceID.spaceID = "a"
        record.id.topicID = "topic"
        record.text = "Queued attachment"
        record.annotations = [SendRequests.uploadAnnotation(upload)]
        record.unsentType = 1
        record.delivery.scheduledTime.seconds = 2_500_000_000
        return record
    }
}

actor ScheduledMessageTransport: HTTPTransport {
    let base = ActionTransport(kind: .space)
    let forwardSource: ForwardTransport?
    private let dropsUploadsOnEdit: Bool
    private(set) var writes: [String] = []
    private(set) var createdAnnotations: [Annotation] = []
    private(set) var createdReference: UnsentMessageReference?
    private(set) var deliveredReference: SendReplyTarget?
    private(set) var editedAnnotations: [Annotation] = []
    private var queued: UnsentMessage?

    init(
        queued: UnsentMessage? = nil, dropsUploadsOnEdit: Bool = false, forwardSource: ForwardTransport? = nil
    ) {
        self.queued = queued
        self.dropsUploadsOnEdit = dropsUploadsOnEdit
        self.forwardSource = forwardSource
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let operation = request.url.lastPathComponent
        let data = request.body ?? Data()
        switch operation {
        case "list_unsent_messages":
            let list = try ListUnsentMessagesRequest(serializedBytes: data)
            #expect(list.scope.unsentType == 1 && list.scope.listMode == 1)
            var result = ListUnsentMessagesResponse()
            result.revision.timestamp = 10
            if let queued, !list.scope.hasGroupID || list.scope.groupID == queued.id.groupID {
                result.messages = [queued]
            }
            return try ok(result)
        case "create_unsent_message":
            return try createSchedule(data, operation: operation)
        case "update_unsent_message":
            return try updateSchedule(data, operation: operation)
        case "delete_unsent_message":
            return try delete(data, operation: operation)
        case "create_message":
            return try deliverReply(data, operation: operation)
        case "create_topic":
            return try deliverTopic(data, operation: operation)
        case "list_messages":
            if let forwardSource {
                return try await forwardSource.send(request)
            }
            return try await base.send(request)
        default:
            return try await base.send(request)
        }
    }

    private func createSchedule(_ data: Data, operation: String) throws -> HTTPResponse {
        let create = try CreateUnsentMessageRequest(serializedBytes: data)
        #expect(create.message.id.topicID == (forwardSource == nil ? "topic" : ""))
        #expect(create.message.unsentType == 1)
        if create.message.hasReference, forwardSource == nil {
            #expect(create.message.reference.id.messageID == "quote")
            #expect(create.message.reference.referenceType == 1)
            #expect(create.message.reference.createTime == 1_700_000_000_000_000)
        }
        writes.append(operation)
        createdAnnotations = create.message.annotations
        createdReference = create.message.hasReference ? create.message.reference : nil
        queued = create.message
        return try sparseWriteReply()
    }

    private func updateSchedule(_ data: Data, operation: String) throws -> HTTPResponse {
        let update = try UpdateUnsentMessageRequest(serializedBytes: data)
        let current = try #require(queued)
        #expect(update.message.id == current.id)
        writes.append(operation)
        if update.updateMask.wholeFields == [4, 5] {
            #expect(!update.message.hasDelivery && !update.message.hasReference)
            editedAnnotations = update.message.annotations
            queued?.text = update.message.text
            queued?.annotations = editedAnnotations.filter {
                !dropsUploadsOnEdit || $0.type != .uploadMetadata
            }
        } else {
            #expect(update.updateMask.nestedFields.first?.fieldNumber == 8)
            #expect(!update.message.hasText && !update.message.hasReference)
            queued?.delivery = update.message.delivery
        }
        return try sparseWriteReply()
    }

    private func deliverTopic(_ data: Data, operation: String) throws -> HTTPResponse {
        let request = try CreateTopicRequest(serializedBytes: data)
        let current = try #require(queued)
        #expect(request.messageInfo.unsentMessageID == current.id)
        #expect(request.topicAndMessageID == current.id.localID && !request.hasLocalID)
        #expect(request.groupID == current.id.groupID && request.textBody == current.text)
        deliveredReference = request.messageInfo.replyTo
        writes.append(operation)
        queued = nil
        var response = CreateTopicResponse()
        response.topic.id.groupID = request.groupID
        response.topic.id.topicID = request.topicAndMessageID
        return try ok(response)
    }

    private func delete(_ data: Data, operation: String) throws -> HTTPResponse {
        let remove = try DeleteUnsentMessageRequest(serializedBytes: data)
        #expect(remove.id == queued?.id)
        writes.append(operation)
        queued = nil
        var result = DeleteUnsentMessageResponse()
        result.revision.timestamp = 11
        return try ok(result)
    }

    private func deliverReply(_ data: Data, operation: String) throws -> HTTPResponse {
        let request = try CreateMessageRequest(serializedBytes: data)
        let current = try #require(queued)
        #expect(request.messageInfo.unsentMessageID == current.id)
        #expect(request.messageID == current.id.localID)
        #expect(request.parentID.topicID.groupID == current.id.groupID)
        #expect(request.parentID.topicID.topicID == current.id.topicID)
        #expect(request.textBody == current.text && !request.hasLocalID)
        #expect(request.annotations == current.annotations)
        writes.append(operation)
        queued = nil
        var response = CreateMessageResponse()
        response.message.id.parentID = request.parentID
        response.message.id.messageID = request.messageID
        return try ok(response)
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }

    private func sparseWriteReply() throws -> HTTPResponse {
        var result = WriteUnsentMessageResponse()
        result.revision.timestamp = 10
        return try ok(result)
    }

    private func ok(_ message: some SwiftProtobuf.Message) throws -> HTTPResponse {
        try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: message.serializedData())
    }
}
