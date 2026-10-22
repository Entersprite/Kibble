import ChatKit
import Foundation
import GChatBridgeCore

enum MessageContentMapping {
    private static let styles: [Int: String] = [
        1: "bold", 2: "italic", 3: "strikethrough", 4: "code", 5: "code",
        7: "codeBlock", 8: "underline", 10: "bulletList", 11: "bulletItem"
    ]

    static func content(_ message: GChatBridgeCore.Message) -> MessageContent? {
        guard !message.hasDeleteTime || message.deleteTime == 0 else { return nil }
        let formatting = message.annotations.compactMap { annotation -> MessageFormat? in
            guard case let .formatMetadata(metadata)? = annotation.metadata else { return nil }
            let style = styles[metadata.formatType.rawValue]
                ?? "providerFormat.\(metadata.formatType.rawValue)"
            let format = MessageFormat(
                style: style,
                start: Int(annotation.startIndex),
                length: Int(annotation.length)
            )
            return format.range(in: message.textBody) == nil ? nil : format
        }
        let value = MessageContent(
            formatting: formatting,
            quote: quote(message),
            forwarded: ForwardedMessageMapping.forwarded(message)
        )
        return value.isEmpty ? nil : value
    }

    private static func quote(_ message: GChatBridgeCore.Message) -> MessageQuote? {
        guard message.hasReplyTo, message.replyTo.referenceType == 0 || message.replyTo.referenceType == 1
        else { return nil }
        let quoted = message.replyTo
        guard !quoted.id.messageID.isEmpty,
              let conversation = ChannelEventMapping.conversationID(quoted.id.parentID.topicID.groupID),
              conversation == ChannelEventMapping.conversationID(message.id.parentID.topicID.groupID)
        else { return nil }
        return MessageQuote(message: ChatKit.Message(
            id: ChatKit.Message.ID(quoted.id.messageID), conversationID: conversation,
            threadID: MessageThread.ID(quoted.id.parentID.topicID.topicID),
            sender: Member.ID(ForwardedMessageMapping.author(of: quoted).id), text: quoted.textBody,
            createdAt: Microseconds.date(quoted.createTime), isDeleted: quoted.messageState == 2
        ))
    }

    static func annotations(_ formats: [MessageFormat], text: String) throws -> [Annotation] {
        try formats.map { format in
            guard format.range(in: text) != nil,
                  let kind = styles.sorted(by: { $0.key < $1.key })
                  .first(where: { $0.value == format.style })?.key,
                  let type = FormatMetadata.FormatType(rawValue: kind),
                  let start = Int32(exactly: format.start), let length = Int32(exactly: format.length)
            else { throw ChatError.unsupported(capability: "message formatting") }
            var annotation = Annotation()
            annotation.type = .formatData
            annotation.startIndex = start
            annotation.length = length
            annotation.formatMetadata.formatType = type
            return annotation
        }
    }

    static func target(_ quote: MessageQuote?, in conversation: Conversation.ID) throws -> SendReplyTarget? {
        guard let quote else { return nil }
        guard quote.conversation == conversation, !quote.id.rawValue.isEmpty,
              !quote.thread.rawValue.isEmpty, !quote.isDeleted,
              let group = ChannelEventMapping.groupID(for: conversation) else {
            throw ChatError.decoding("The quoted message cannot be addressed in this conversation")
        }
        var target = SendReplyTarget()
        target.id.parentID.topicID.groupID = group
        target.id.parentID.topicID.topicID = quote.thread.rawValue
        target.id.messageID = quote.id.rawValue
        target.createTime = Microseconds.from(quote.createdAt)
        return target
    }
}
