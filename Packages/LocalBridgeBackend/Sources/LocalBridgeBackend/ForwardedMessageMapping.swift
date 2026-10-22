import ChatKit
import Foundation
import GChatBridgeCore

enum ForwardedMessageMapping {
    /// Reference type 2 is the web client's Forward message action. Type 1 is
    /// an ordinary quoted reply; absence retains the older quote shape, except
    /// for a source in another conversation, which no quote can have.
    static func forwarded(_ message: GChatBridgeCore.Message) -> ForwardedMessage? {
        guard message.hasReplyTo, isForward(message) else { return nil }
        let value = message.replyTo
        let author = author(of: value)
        // A reference that does not address its source still renders: the
        // author and text are display data, and nothing is read or opened
        // from the source. The outer message's address stands in only so the
        // shared mapping runs; the snapshot's own address is then left empty.
        let addressed = ChannelEventMapping.conversationID(value.id.parentID.topicID.groupID) != nil
            && !value.id.messageID.isEmpty
        var original = GChatBridgeCore.Message()
        original.id = addressed ? value.id : message.id
        original.creator.userID.id = author.id
        original.textBody = value.textBody
        original.createTime = value.hasOriginalCreateTime ? value.originalCreateTime : value.createTime
        original.annotations = value.annotations
        if value.messageState == 2 {
            original.deleteTime = max(original.createTime, 1)
        }
        guard let mapped = ChannelEventMapping.domainMessage(original) else { return nil }
        var source = MessageQuote(message: mapped)
        source.text = mapped.isDeleted ? "" : mapped.text
        if !addressed {
            source.id = ChatKit.Message.ID("")
            source.conversation = Conversation.ID("")
            source.thread = MessageThread.ID("")
        }
        return ForwardedMessage(
            source: source,
            senderName: author.name.map { String($0.prefix(200)) },
            senderAvatarURL: author.avatar,
            mentions: mapped.mentions, formatting: mapped.content?.formatting ?? [],
            attachments: mapped.isDeleted ? [] : mapped.attachments,
            links: mapped.isDeleted ? [] : mapped.links
        )
    }

    private static func isForward(_ message: GChatBridgeCore.Message) -> Bool {
        let reference = message.replyTo
        switch reference.referenceType {
        case 2:
            return true
        case 0:
            guard let source = ChannelEventMapping.conversationID(reference.id.parentID.topicID.groupID)
            else { return false }
            return source != ChannelEventMapping.conversationID(message.id.parentID.topicID.groupID)
        default:
            return false
        }
    }

    struct Author {
        var id: String
        var name: String?
        var avatar: URL?
    }

    /// Who wrote a referenced message. The nested profile (field 5) comes
    /// first, then the bare id (field 4), then the second profile (field 12):
    /// a reference need not carry all three, and the first one present names
    /// the author for quotes and forwards alike.
    static func author(of value: ReplyToMessage) -> Author {
        let profiles = [value.hasSender ? value.sender : nil, value.hasSenderAgain ? value.senderAgain : nil]
            .compactMap(\.self)
        let id = [
            value.hasSender ? value.sender.userID.id : "",
            value.senderID.id,
            value.hasSenderAgain ? value.senderAgain.userID.id : ""
        ].first { !$0.isEmpty } ?? ""
        let name = profiles.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let avatar = profiles.lazy.compactMap { ChannelEventMapping.webURL($0.avatarURL) }
            .first { $0.scheme?.lowercased() == "https" }
        return Author(id: id, name: name, avatar: avatar)
    }
}
