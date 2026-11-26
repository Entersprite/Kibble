import Foundation

/// The source snapshot supplied with a forwarded message. It is display data,
/// not permission to read or modify the original conversation.
public struct ForwardedMessage: Codable, Hashable, Sendable {
    public var source: MessageQuote
    public var senderName: String?
    public var senderAvatarURL: URL?
    public var mentions: [Mention]
    public var formatting: [MessageFormat]
    public var customEmoji: [MessageCustomEmoji]
    public var attachments: [Attachment]
    public var links: [MessageLink]

    public init(
        source: MessageQuote, senderName: String? = nil, senderAvatarURL: URL? = nil,
        mentions: [Mention] = [], formatting: [MessageFormat] = [], customEmoji: [MessageCustomEmoji] = [],
        attachments: [Attachment] = [], links: [MessageLink] = []
    ) {
        self.source = source
        self.senderName = senderName
        self.senderAvatarURL = senderAvatarURL
        self.mentions = mentions
        self.formatting = formatting
        self.customEmoji = customEmoji
        self.attachments = attachments
        self.links = links
    }

    private enum CodingKeys: String, CodingKey {
        case source, senderName, senderAvatarURL, mentions, formatting, attachments, links, customEmoji
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(MessageQuote.self, forKey: .source)
        senderName = try container.decodeIfPresent(String.self, forKey: .senderName)
        senderAvatarURL = try container.decodeIfPresent(URL.self, forKey: .senderAvatarURL)
        mentions = try container.decodeIfPresent([Mention].self, forKey: .mentions) ?? []
        formatting = try container.decodeIfPresent([MessageFormat].self, forKey: .formatting) ?? []
        customEmoji = try container.decodeIfPresent([MessageCustomEmoji].self, forKey: .customEmoji) ?? []
        attachments = try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        links = try container.decodeIfPresent([MessageLink].self, forKey: .links) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(senderName, forKey: .senderName)
        try container.encodeIfPresent(senderAvatarURL, forKey: .senderAvatarURL)
        try container.encode(mentions, forKey: .mentions)
        try container.encode(formatting, forKey: .formatting)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(links, forKey: .links)
        if !customEmoji.isEmpty {
            try container.encode(customEmoji, forKey: .customEmoji)
        }
    }

    public var message: Message {
        Message(
            id: source.id, conversationID: source.conversation, threadID: source.thread,
            sender: source.sender, text: source.isDeleted ? "" : source.text, createdAt: source.createdAt,
            isDeleted: source.isDeleted, attachments: source.isDeleted ? [] : attachments,
            mentions: source.isDeleted ? [] : mentions, links: source.isDeleted ? [] : links,
            content: source.isDeleted ? nil : MessageContent(formatting: formatting, customEmoji: customEmoji)
        )
    }
}
