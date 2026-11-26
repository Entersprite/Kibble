import ChatKit
import Foundation
import GChatBridgeCore

enum ScheduledMessageMapping {
    static func address(_ id: UnsentMessageId) -> ScheduledMessageAddress? {
        guard let location = UnsentMessageMapping.address(id) else { return nil }
        return ScheduledMessageAddress(
            conversation: location.conversation, thread: location.thread,
            queueID: id.localID
        )
    }

    static func wireID(_ address: ScheduledMessageAddress) throws -> UnsentMessageId {
        try UnsentMessageMapping.wireID(
            address: ComposerDraftAddress(conversation: address.conversation, thread: address.thread),
            recordID: address.queueID
        )
    }

    static func message(_ record: UnsentMessage) throws -> ScheduledMessage {
        let timestamp = record.delivery.scheduledTime
        guard record.unsentType == 1, let address = address(record.id),
              timestamp.hasSeconds, (-62_135_596_800 ... 253_402_300_799).contains(timestamp.seconds),
              (0 ..< 1_000_000_000).contains(timestamp.nanos) else {
            throw ChatError.decoding("The service returned an invalid scheduled message.")
        }
        let body = UnsentMessageMapping.composedBody(record, in: address.conversation)
        let uploads = editableUploads(in: record)
        let names = record.annotations.lazy.compactMap { annotation -> String? in
            guard case let .uploadMetadata(upload)? = annotation.metadata,
                  !upload.attachmentToken.isEmpty else { return nil }
            let name = upload.contentName
            return name.isEmpty ? "Attachment" : String(name.prefix(256))
        }.prefix(16)
        let count = body.mentions.count + (body.content?.formatting.count ?? 0)
            + (body.content?.customEmoji.count ?? 0) + uploads.count
        let forwarded = forward(in: record) != nil
        let understood = !record.hasReference || [0, 1].contains(record.reference.referenceType) || forwarded
        let canEdit = count == record.annotations.count && understood
            && (try? MessageContentMapping.annotations(body.content?.formatting ?? [], text: body.text)) !=
            nil
        return ScheduledMessage(
            id: address, body: body,
            deliveryTime: Date(timeIntervalSince1970: Double(timestamp.seconds) + Double(timestamp.nanos) /
                1e9),
            deliveryFailed: record.delivery.status == 2,
            canEditBody: canEdit,
            attachmentNames: names.isEmpty ? nil : Array(names),
            isForward: forwarded ? true : nil
        )
    }

    static func forward(in record: UnsentMessage) -> UnsentMessageReference? {
        let reference = record.reference
        let topic = reference.id.parentID.topicID
        guard reference.referenceType == 2, !reference.id.messageID.isEmpty, !topic.topicID.isEmpty,
              ChannelEventMapping.conversationID(topic.groupID) != nil else { return nil }
        return reference
    }

    static func preservesForward(_ expected: UnsentMessageReference?, in record: UnsentMessage) -> Bool {
        guard let expected, expected.referenceType == 2 else { return true }
        return forward(in: record)?.id == expected.id
    }

    /// Text edits may preserve ordinary file chips. Other attachment shapes
    /// can depend on their original offsets and still require the web editor.
    static func editableUploads(in record: UnsentMessage) -> [Annotation] {
        record.annotations.filter {
            $0.type == .uploadMetadata && !$0.uploadMetadata.attachmentToken.isEmpty
                && $0.startIndex == 0 && $0.length == 0
        }
    }
}

enum UnsentMessageMapping {
    static func wireID(address: ComposerDraftAddress, recordID: String) throws -> UnsentMessageId {
        guard !recordID.isEmpty, let group = ChannelEventMapping.groupID(for: address.conversation),
              address.thread?.rawValue.isEmpty != true else {
            throw ChatError.decoding("This unsent message cannot be addressed.")
        }
        var id = UnsentMessageId()
        id.localID = recordID
        id.groupID = group
        if let thread = address.thread {
            id.topicID = thread.rawValue
        }
        return id
    }

    static func reference(
        _ quote: MessageQuote?, in conversation: Conversation.ID
    ) throws -> UnsentMessageReference? {
        guard let target = try MessageContentMapping.target(quote, in: conversation) else { return nil }
        return reference(target, type: 1)
    }

    static func reference(_ target: SendReplyTarget, type: Int32) -> UnsentMessageReference {
        var reference = UnsentMessageReference()
        reference.id = target.id
        reference.createTime = target.createTime
        reference.referenceType = type
        return reference
    }

    static func address(_ id: UnsentMessageId) -> ComposerDraftAddress? {
        guard let conversation = ChannelEventMapping.conversationID(id.groupID),
              !id.localID.isEmpty, !id.hasTopicID || !id.topicID.isEmpty else { return nil }
        return ComposerDraftAddress(
            conversation: conversation, thread: id.hasTopicID ? MessageThread.ID(id.topicID) : nil
        )
    }

    static func composedBody(
        _ record: UnsentMessage,
        in conversation: Conversation.ID
    ) -> ComposedMessage {
        var annotated = GChatBridgeCore.Message()
        annotated.textBody = record.text
        annotated.annotations = record.annotations
        var content = MessageContentMapping.content(annotated) ?? MessageContent()
        for index in content.customEmoji.indices {
            content.customEmoji[index].emoji.imageToken = nil
        }
        content.quote = quote(record.reference, in: conversation)
        return ComposedMessage(
            text: record.text, mentions: ChannelEventMapping.mentions(record.annotations), content: content
        )
    }

    private static func quote(
        _ reference: UnsentMessageReference,
        in conversation: Conversation.ID
    ) -> MessageQuote? {
        let id = reference.id
        let topic = id.parentID.topicID
        guard [0, 1].contains(reference.referenceType), !id.messageID.isEmpty, !topic.topicID.isEmpty,
              ChannelEventMapping.conversationID(topic.groupID) == conversation else { return nil }
        return MessageQuote(message: ChatKit.Message(
            id: .init(id.messageID), conversationID: conversation, threadID: .init(topic.topicID),
            sender: .init(""), text: reference.text, createdAt: Microseconds.date(reference.createTime)
        ))
    }
}
