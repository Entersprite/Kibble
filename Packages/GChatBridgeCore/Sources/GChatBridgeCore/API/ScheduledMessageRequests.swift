import Foundation

/// The web client's personal unsent-message resource with type `1` (scheduled).
/// Its delivery time is held by the provider, independent of the send queue.
public enum ScheduledMessageRequests {
    public enum Failure: Error, Equatable {
        case invalidAddress
        case invalidDeliveryTime
        case invalidScheduledRecord
    }

    public enum DeliveryRequest: Sendable {
        case topic(CreateTopicRequest)
        case reply(CreateMessageRequest)
    }

    /// The web client uses an eight-byte value encoded as unpadded Base64URL
    /// for a new unsent identity. Existing records keep their original ID.
    public static func makeQueueID() -> String {
        let value = UInt64.random(in: .min ... .max).bigEndian
        let bytes = withUnsafeBytes(of: value) { Data($0) }
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func create(
        _ id: UnsentMessageId,
        text: String,
        annotations: [Annotation] = [],
        reference: UnsentMessageReference? = nil,
        deliveryTime: Date,
        now: Date = Date()
    ) throws -> CreateUnsentMessageRequest {
        try validate(id)
        var request = CreateUnsentMessageRequest()
        request.requestHeader = APIRequestHeader.make()
        request.message.id = id
        request.message.text = text
        request.message.annotations = annotations
        if let reference {
            request.message.reference = reference
        }
        request.message.unsentType = 1
        request.message.delivery = try delivery(at: deliveryTime, now: now)
        request.message.clientSyncValue = ""
        return request
    }

    public static func list(
        after cursor: String? = nil,
        in group: GroupId? = nil
    ) -> ListUnsentMessagesRequest {
        var request = ListUnsentMessagesRequest()
        request.requestHeader = APIRequestHeader.make()
        request.options.pageSize = 30
        if let cursor {
            request.options.cursor = cursor
        }
        request.scope.unsentType = 1
        request.scope.listMode = 1
        if let group {
            request.scope.groupID = group
        }
        return request
    }

    public static func edit(
        _ id: UnsentMessageId,
        text: String,
        annotations: [Annotation]
    ) throws -> UpdateUnsentMessageRequest {
        try validate(id)
        var request = UpdateUnsentMessageRequest()
        request.requestHeader = APIRequestHeader.make()
        request.message.id = id
        request.message.text = text
        request.message.annotations = annotations
        request.updateMask.wholeFields = [4, 5]
        request.updateMask.inverted = false
        return request
    }

    public static func reschedule(
        _ id: UnsentMessageId,
        deliveryTime: Date,
        now: Date = Date()
    ) throws -> UpdateUnsentMessageRequest {
        try validate(id)
        var timestamp = UnsentMessageUpdateMask.NestedField()
        timestamp.fieldNumber = 8
        timestamp.mask.wholeFields = [1]
        timestamp.mask.inverted = false
        var request = UpdateUnsentMessageRequest()
        request.requestHeader = APIRequestHeader.make()
        request.message.id = id
        request.message.delivery = try delivery(at: deliveryTime, now: now)
        request.updateMask.nestedFields = [timestamp]
        request.updateMask.inverted = false
        return request
    }

    public static func convertDraft(
        _ id: UnsentMessageId, text: String, annotations: [Annotation],
        reference: UnsentMessageReference?, deliveryTime: Date, now: Date = Date()
    ) throws -> UpdateUnsentMessageRequest {
        var request = try reschedule(id, deliveryTime: deliveryTime, now: now)
        request.message.text = text
        request.message.annotations = annotations
        if let reference {
            request.message.reference = reference
        }
        request.message.unsentType = 1
        request.updateMask.wholeFields = [4, 5, 6, 7]
        return request
    }

    public static func cancel(_ id: UnsentMessageId) throws -> DeleteUnsentMessageRequest {
        try validate(id)
        var request = DeleteUnsentMessageRequest()
        request.requestHeader = APIRequestHeader.make()
        request.id = id
        return request
    }

    /// Uses the stored queue ID for the send identity and its original address
    /// for provider-side consumption of that same item.
    public static func sendNow(_ record: UnsentMessage) throws -> DeliveryRequest {
        let id = record.id
        try validate(id)
        guard record.unsentType == 1 else { throw Failure.invalidScheduledRecord }
        let quote = try record.hasReference ? sendReference(record.reference) : nil
        if id.hasTopicID {
            var request = SendRequests.createMessage(
                group: id.groupID, topicID: id.topicID, text: record.text,
                localID: id.localID, annotations: record.annotations, quote: quote, unsent: id
            )
            request.clearLocalID()
            request.messageID = id.localID
            return .reply(request)
        }
        var request = SendRequests.createTopic(
            group: id.groupID, text: record.text, localID: id.localID,
            annotations: record.annotations, quote: quote, unsent: id
        )
        request.clearLocalID()
        request.topicAndMessageID = id.localID
        return .topic(request)
    }

    private static func sendReference(_ stored: UnsentMessageReference) throws -> SendReplyTarget {
        guard stored.hasID, !stored.id.messageID.isEmpty else { throw Failure.invalidScheduledRecord }
        var target = SendReplyTarget()
        target.id = stored.id
        if stored.hasCreateTime {
            target.createTime = stored.createTime
        }
        if stored.hasReferenceType {
            target.referenceType = stored.referenceType
        }
        return target
    }

    private static func validate(_ id: UnsentMessageId) throws {
        let group = id.groupID
        guard !id.localID.isEmpty, !group.spaceID.spaceID.isEmpty || !group.dmID.dmID.isEmpty,
              !id.hasTopicID || !id.topicID.isEmpty else {
            throw Failure.invalidAddress
        }
    }

    private static func delivery(at date: Date, now: Date) throws -> UnsentMessageDelivery {
        let time = date.timeIntervalSince1970
        let seconds = time.rounded(.down)
        // Timestamp limits from the protobuf calendar range, years 0001 through 9999.
        guard date > now, (-62_135_596_800 ... 253_402_300_799).contains(seconds) else {
            throw Failure.invalidDeliveryTime
        }
        var delivery = UnsentMessageDelivery()
        delivery.scheduledTime.seconds = Int64(seconds)
        delivery.scheduledTime.nanos = Int32(min((time - seconds) * 1_000_000_000, 999_999_999))
        return delivery
    }
}

public extension APIMethod where Request == CreateUnsentMessageRequest,
    Response == WriteUnsentMessageResponse {
    static var createUnsentMessage: Self {
        Self("create_unsent_message")
    }
}

public extension APIMethod where Request == UpdateUnsentMessageRequest,
    Response == WriteUnsentMessageResponse {
    static var updateUnsentMessage: Self {
        Self("update_unsent_message")
    }
}

public extension APIMethod where Request == DeleteUnsentMessageRequest,
    Response == DeleteUnsentMessageResponse {
    static var deleteUnsentMessage: Self {
        Self("delete_unsent_message")
    }
}

public extension APIMethod where Request == ListUnsentMessagesRequest,
    Response == ListUnsentMessagesResponse {
    static var listUnsentMessages: Self {
        Self("list_unsent_messages")
    }
}
