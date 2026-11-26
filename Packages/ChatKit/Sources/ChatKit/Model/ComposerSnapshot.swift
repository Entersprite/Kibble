import Foundation

/// Local unsent composition, scoped by the account's replica. Not a send operation.
///
/// `formatting` is the styles the composer draws (bold as bold), as spans
/// over `text` itself, untrimmed. A snapshot saved before the composer drew
/// styles has none, and an empty list is not written, so an unformatted
/// draft is stored exactly as before.
public struct ComposerSnapshot: Codable, Equatable, Sendable {
    public var conversation: Conversation.ID
    public var thread: MessageThread.ID?
    public var text: String
    public var mentions: [Mention]
    public var caret: Int
    public var quote: MessageQuote?
    public var formatting: [MessageFormat]
    public var customEmoji: [MessageCustomEmoji]

    public init(
        conversation: Conversation.ID, thread: MessageThread.ID? = nil,
        text: String, mentions: [Mention] = [], caret: Int = 0, quote: MessageQuote? = nil,
        formatting: [MessageFormat] = [], customEmoji: [MessageCustomEmoji] = []
    ) {
        self.conversation = conversation
        self.thread = thread
        self.text = text
        self.mentions = mentions
        self.caret = caret
        self.quote = quote
        self.formatting = formatting
        self.customEmoji = customEmoji
    }

    private enum CodingKeys: String, CodingKey {
        case conversation, thread, text, mentions, caret, quote, formatting, customEmoji
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversation = try container.decode(Conversation.ID.self, forKey: .conversation)
        thread = try container.decodeIfPresent(MessageThread.ID.self, forKey: .thread)
        text = try container.decode(String.self, forKey: .text)
        mentions = try container.decode([Mention].self, forKey: .mentions)
        caret = try container.decode(Int.self, forKey: .caret)
        quote = try container.decodeIfPresent(MessageQuote.self, forKey: .quote)
        formatting = try container.decodeIfPresent([MessageFormat].self, forKey: .formatting) ?? []
        customEmoji = try container.decodeIfPresent([MessageCustomEmoji].self, forKey: .customEmoji) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(conversation, forKey: .conversation)
        try container.encodeIfPresent(thread, forKey: .thread)
        try container.encode(text, forKey: .text)
        try container.encode(mentions, forKey: .mentions)
        try container.encode(caret, forKey: .caret)
        try container.encodeIfPresent(quote, forKey: .quote)
        if !customEmoji.isEmpty {
            try container.encode(customEmoji, forKey: .customEmoji)
        }
        if !formatting.isEmpty {
            try container.encode(formatting, forKey: .formatting)
        }
    }
}
