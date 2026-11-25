import Foundation
import Testing
@testable import GChatBridgeCore

struct ScheduledMessageRequestsTests {
    @Test func createAddressesAReplyAndIncludesTheDeliveryTimestamp() throws {
        let request = try createRequest()
        let wire: Data = try request.serializedBytes()
        let message = try #require(ProtoFieldScan.payloads(ofField: 2, in: wire).first)
        let identity = try #require(ProtoFieldScan.payloads(ofField: 1, in: message).first)
        let delivery = try #require(ProtoFieldScan.payloads(ofField: 8, in: message).first)
        let timestamp = try #require(ProtoFieldScan.payloads(ofField: 1, in: delivery).first)

        #expect(ProtoFieldScan.payloads(ofField: 1, in: wire).count == 1)
        #expect(ProtoFieldScan.payloads(ofField: 1, in: identity) == [Data("queued-1".utf8)])
        #expect(ProtoFieldScan.payloads(ofField: 2, in: identity).count == 1)
        #expect(ProtoFieldScan.payloads(ofField: 3, in: identity) == [Data("topic-1".utf8)])
        #expect(ProtoFieldScan.payloads(ofField: 4, in: message) == [Data("Scheduled sample".utf8)])
        #expect(ProtoFieldScan.varintValues(ofField: 7, in: message) == [1])
        #expect(ProtoFieldScan.varintValues(ofField: 1, in: timestamp) == [200])
        #expect(ProtoFieldScan.varintValues(ofField: 2, in: timestamp) == [250_000_000])
        #expect(ProtoFieldScan.payloads(ofField: 9, in: message) == [Data()])
    }

    @Test func rescheduleAndEditUpdateDisjointFields() throws {
        let reschedule = try ScheduledMessageRequests.reschedule(
            address(), deliveryTime: Date(timeIntervalSince1970: 300), now: Date(timeIntervalSince1970: 100)
        )
        let edit = try ScheduledMessageRequests.edit(address(), text: "Edited sample", annotations: [])
        let rescheduleBytes: Data = try reschedule.serializedBytes()
        let editBytes: Data = try edit.serializedBytes()
        #expect(ProtoFieldScan.payloads(ofField: 3, in: rescheduleBytes) == [
            Data([0x0A, 8, 0x08, 8, 0x12, 4, 0x10, 1, 0x18, 0, 0x18, 0])
        ])
        #expect(ProtoFieldScan.payloads(ofField: 3, in: editBytes) == [Data([0x10, 4, 0x10, 5, 0x18, 0])])
        #expect(reschedule.message.id == edit.message.id)
        #expect(!reschedule.message.hasText)
        #expect(!edit.message.hasDelivery)
        #expect(!reschedule.message.hasUnsentType && !edit.message.hasUnsentType)
    }

    @Test(arguments: [1, 2])
    func onlyScheduledForwardsDeclareProviderSupport(referenceType: Int32) throws {
        var reference = UnsentMessageReference()
        reference.id.messageID = "original"
        reference.referenceType = referenceType
        let request = try ScheduledMessageRequests.create(
            address(), text: "Scheduled sample", reference: reference,
            deliveryTime: Date(timeIntervalSince1970: 200), now: Date(timeIntervalSince1970: 100)
        )
        let wire: Data = try request.serializedBytes()
        let header = try #require(ProtoFieldScan.payloads(ofField: 1, in: wire).first)
        let features = ProtoFieldScan.payloads(ofField: 5, in: header)
        if referenceType == 2 {
            let advertised = try #require(features.first)
            #expect(ProtoFieldScan.varintValues(ofField: 53, in: advertised) == [2])
        } else {
            #expect(features.isEmpty)
        }
    }

    @Test func conversionChangesTypeAndDeliveryOnTheOriginalAddressAndCanClearAQuote() throws {
        let update = try ScheduledMessageRequests.convertDraft(
            address(), text: "Edited draft", annotations: [], reference: nil,
            deliveryTime: Date(timeIntervalSince1970: 300), now: Date(timeIntervalSince1970: 100)
        )
        let wire: Data = try update.serializedBytes()
        let record = try #require(ProtoFieldScan.payloads(ofField: 2, in: wire).first)
        #expect(update.message.id == address())
        #expect(ProtoFieldScan.varintValues(ofField: 7, in: record) == [1])
        #expect(update.message.delivery.scheduledTime.seconds == 300)
        #expect(!update.message.hasReference && !update.message.hasClientSyncValue)
        #expect(update.updateMask.wholeFields == [4, 5, 6, 7])
        #expect(update.updateMask.nestedFields.first?.fieldNumber == 8)
        #expect(update.updateMask.nestedFields.first?.mask.wholeFields == [1])
    }

    @Test func accountListingRequestsScheduledItemsAndUsesTheOpaqueCursor() throws {
        let initial = ScheduledMessageRequests.list()
        #expect(!initial.options.hasCursor)
        let page = ScheduledMessageRequests.list(after: "opaque-page")
        let wire: Data = try page.serializedBytes()
        #expect(ProtoFieldScan.payloads(ofField: 2, in: wire) == [
            Data([0x28, 30, 0x32, 11]) + Data("opaque-page".utf8)
        ])
        #expect(ProtoFieldScan.payloads(ofField: 3, in: wire) == [Data([0x18, 1, 0x28, 1])])
    }

    @Test func invalidAddressesAndPastDeliveryTimesAreRejected() {
        let now = Date(timeIntervalSince1970: 100)
        #expect(throws: ScheduledMessageRequests.Failure.invalidDeliveryTime) {
            try ScheduledMessageRequests.create(address(), text: "Sample", deliveryTime: now, now: now)
        }
        #expect(throws: ScheduledMessageRequests.Failure.invalidAddress) {
            try ScheduledMessageRequests.cancel(UnsentMessageId())
        }
    }

    @Test func sendNowUsesTheQueuedIdentityInBothTopicFields() throws {
        var record = try createRequest().message
        record.id.clearTopicID()
        guard case let .topic(request) = try ScheduledMessageRequests.sendNow(record) else {
            Issue.record("Expected a top-level send")
            return
        }
        let wire: Data = try request.serializedBytes()
        let info = try #require(ProtoFieldScan.payloads(ofField: 9, in: wire).first)
        #expect(ProtoFieldScan.payloads(ofField: 4, in: wire).isEmpty)
        #expect(ProtoFieldScan.payloads(ofField: 7, in: wire) == [Data(record.id.localID.utf8)])
        #expect(try ProtoFieldScan.payloads(ofField: 5, in: info) == [record.id.serializedBytes()])
        #expect(request.groupID == record.id.groupID)
        #expect(request.textBody == record.text)
    }

    @Test func sendNowPreservesTheQueuedReplyParentAndQuote() throws {
        var record = try createRequest().message
        record.reference.id.messageID = "quoted-1"
        record.reference.createTime = 42
        record.reference.referenceType = 1
        guard case let .reply(request) = try ScheduledMessageRequests.sendNow(record) else {
            Issue.record("Expected a threaded send")
            return
        }
        let wire: Data = try request.serializedBytes()
        let info = try #require(ProtoFieldScan.payloads(ofField: 7, in: wire).first)
        #expect(ProtoFieldScan.payloads(ofField: 4, in: wire).isEmpty)
        #expect(ProtoFieldScan.payloads(ofField: 6, in: wire) == [Data(record.id.localID.utf8)])
        #expect(try ProtoFieldScan.payloads(ofField: 5, in: info) == [record.id.serializedBytes()])
        #expect(request.parentID.topicID.topicID == record.id.topicID)
        let quote = try #require(ProtoFieldScan.payloads(ofField: 3, in: info).first)
        #expect(try ProtoFieldScan.payloads(ofField: 1, in: quote) == [record.reference.id.serializedBytes()])
        #expect(ProtoFieldScan.varintValues(ofField: 2, in: quote) == [42])
        #expect(ProtoFieldScan.varintValues(ofField: 4, in: quote) == [1])
    }

    @Test func operationsUseTheirAccountScopedRoutesAndDecodeTheirOwnReplies() async throws {
        let create = try createRequest()
        let id = create.message.id
        var write = WriteUnsentMessageResponse()
        write.message = create.message
        write.revision.timestamp = 10
        var list = ListUnsentMessagesResponse()
        list.messages = [write.message]
        list.nextCursor = "next-page"
        var delete = DeleteUnsentMessageResponse()
        delete.revision.timestamp = 11
        let writeReply = try reply(write.serializedBytes())
        let transport = try FakeHTTPTransport(responses: [
            writeReply, reply(list.serializedBytes()), writeReply, reply(delete.serializedBytes())
        ])
        let cookies = try #require(SessionCookies(cookies: [.init(name: "SID", value: "fixture")]))
        let client = ProtoAPIClient(
            transport: transport, endpoints: ChatEndpoints(), credentials: SessionCredentials(cookies),
            xsrfToken: nil
        )
        let created = try await client.call(.createUnsentMessage, create)
        let listed = try await client.call(.listUnsentMessages, ScheduledMessageRequests.list())
        let updated = try await client.call(
            .updateUnsentMessage, ScheduledMessageRequests.edit(id, text: "Edited sample", annotations: [])
        )
        let deleted = try await client.call(.deleteUnsentMessage, ScheduledMessageRequests.cancel(id))
        #expect(created.message.id == id && updated.revision.timestamp == 10)
        #expect(listed.messages.map(\.id) == [id] && listed.nextCursor == "next-page")
        #expect(deleted.revision.timestamp == 11)
        let sent = await transport.sent
        #expect(sent.map(\.url.lastPathComponent) == [
            "create_unsent_message", "list_unsent_messages", "update_unsent_message", "delete_unsent_message"
        ])
        #expect(sent.allSatisfy { $0.method == .post && $0.url.path.contains("/api/") })
        let body = try #require(sent.last?.body)
        #expect(try DeleteUnsentMessageRequest(serializedBytes: body).id == id)
    }

    private func createRequest() throws -> CreateUnsentMessageRequest {
        try ScheduledMessageRequests.create(
            address(), text: "Scheduled sample", deliveryTime: Date(timeIntervalSince1970: 200.25),
            now: Date(timeIntervalSince1970: 100)
        )
    }

    private func address() -> UnsentMessageId {
        var address = UnsentMessageId()
        address.localID = "queued-1"
        address.groupID.spaceID.spaceID = "space-1"
        address.topicID = "topic-1"
        return address
    }

    private func reply(_ body: Data) -> HTTPResponse {
        HTTPResponse(status: 200, headers: HTTPHeaders([]), body: body)
    }
}
