import Foundation

/// The source snapshot supplied with a forwarded message. It is display data,
/// not permission to read or modify the original conversation.
public struct ForwardedMessage: Codable, Hashable, Sendable {
    public var source: MessageQuote
    public var senderName: String?
    public var senderAvatarURL: URL?
    public var mentions: [Mention]
    public var formatting: [MessageFormat]
    public var attachments: [Attachment]
    public var links: [MessageLink]

    public init(
        source: MessageQuote, senderName: String? = nil, senderAvatarURL: URL? = nil,
        mentions: [Mention] = [], formatting: [MessageFormat] = [],
        attachments: [Attachment] = [], links: [MessageLink] = []
    ) {
        self.source = source
        self.senderName = senderName
        self.senderAvatarURL = senderAvatarURL
        self.mentions = mentions
        self.formatting = formatting
        self.attachments = attachments
        self.links = links
    }

    private enum CodingKeys: String, CodingKey {
        case source, senderName, senderAvatarURL, mentions, formatting, attachments, links
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(MessageQuote.self, forKey: .source)
        senderName = try container.decodeIfPresent(String.self, forKey: .senderName)
        senderAvatarURL = try container.decodeIfPresent(URL.self, forKey: .senderAvatarURL)
        mentions = try container.decodeIfPresent([Mention].self, forKey: .mentions) ?? []
        formatting = try container.decodeIfPresent([MessageFormat].self, forKey: .formatting) ?? []
        attachments = try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        links = try container.decodeIfPresent([MessageLink].self, forKey: .links) ?? []
    }

    public var message: Message {
        Message(
            id: source.id, conversationID: source.conversation, threadID: source.thread,
            sender: source.sender, text: source.isDeleted ? "" : source.text, createdAt: source.createdAt,
            isDeleted: source.isDeleted, attachments: source.isDeleted ? [] : attachments,
            mentions: source.isDeleted ? [] : mentions, links: source.isDeleted ? [] : links,
            content: source.isDeleted ? nil : MessageContent(formatting: formatting)
        )
    }
}
