import ChatKit
import Foundation
import GChatBridgeCore

enum ForwardedMessageMapping {
    /// Reference type 2 is the web client's Forward message action. Type 1 is
    /// an ordinary quoted reply; absence retains the older quote shape.
    static func forwarded(_ message: GChatBridgeCore.Message) -> ForwardedMessage? {
        guard message.hasReplyTo, message.replyTo.referenceType == 2 else { return nil }
        let value = message.replyTo
        guard ChannelEventMapping.conversationID(value.id.parentID.topicID.groupID) != nil,
              !value.id.messageID.isEmpty else { return nil }
        let sender = value.hasSender && !value.sender.userID.id.isEmpty ? value.sender.userID : value.senderID
        var original = GChatBridgeCore.Message()
        original.id = value.id
        original.creator.userID = sender
        original.textBody = value.textBody
        original.createTime = value.hasOriginalCreateTime ? value.originalCreateTime : value.createTime
        original.annotations = value.annotations
        if value.messageState == 2 {
            original.deleteTime = max(original.createTime, 1)
        }
        guard let mapped = ChannelEventMapping.domainMessage(original) else { return nil }
        var source = MessageQuote(message: mapped)
        source.text = mapped.isDeleted ? "" : mapped.text
        return ForwardedMessage(
            source: source,
            senderName: value.sender.name.isEmpty ? nil : String(value.sender.name.prefix(200)),
            senderAvatarURL: ChannelEventMapping.webURL(value.sender.avatarURL).flatMap {
                $0.scheme?.lowercased() == "https" ? $0 : nil
            },
            mentions: mapped.mentions, formatting: mapped.content?.formatting ?? [],
            attachments: mapped.isDeleted ? [] : mapped.attachments,
            links: mapped.isDeleted ? [] : mapped.links
        )
    }
}
