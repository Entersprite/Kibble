import Foundation

/// Optional message content. Unknown formatting names survive a wire round trip.
public struct MessageContent: Codable, Hashable, Sendable {
    public var formatting: [MessageFormat]
    public var quote: MessageQuote?
    public var forwarded: ForwardedMessage?
    public var forwardSource: MessageQuote?

    public init(
        formatting: [MessageFormat] = [],
        quote: MessageQuote? = nil,
        forwarded: ForwardedMessage? = nil,
        forwardSource: MessageQuote? = nil
    ) {
        self.formatting = formatting
        self.quote = quote
        self.forwarded = forwarded
        self.forwardSource = forwardSource
    }

    public var isEmpty: Bool {
        formatting.isEmpty && quote == nil && forwarded == nil && forwardSource == nil
    }

    private enum CodingKeys: String, CodingKey { case formatting, quote, forwarded, forwardSource }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatting = try container.decodeIfPresent([MessageFormat].self, forKey: .formatting) ?? []
        quote = try container.decodeIfPresent(MessageQuote.self, forKey: .quote)
        forwarded = try container.decodeIfPresent(ForwardedMessage.self, forKey: .forwarded)
        forwardSource = try container.decodeIfPresent(MessageQuote.self, forKey: .forwardSource)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !formatting.isEmpty {
            try container.encode(formatting, forKey: .formatting)
        }
        try container.encodeIfPresent(quote, forKey: .quote)
        try container.encodeIfPresent(forwarded, forKey: .forwarded)
        try container.encodeIfPresent(forwardSource, forKey: .forwardSource)
    }

    public func validate(text: String, conversation: Conversation.ID, capabilities: Capabilities) throws {
        guard forwarded == nil else { throw ChatError.unsupported(capability: "forwarding messages") }
        if let forwardSource {
            guard capabilities.canForwardMessages
            else { throw ChatError.unsupported(capability: "forwardMessages") }
            guard quote == nil, !forwardSource.isDeleted, !forwardSource.id.rawValue.isEmpty,
                  !forwardSource.thread.rawValue.isEmpty, !forwardSource.conversation.rawValue.isEmpty
            else { throw ChatError.decoding("Invalid forward source") }
        }
        guard formatting.isEmpty || capabilities.canFormatMessages else {
            throw ChatError.unsupported(capability: "formattedMessages")
        }
        guard quote == nil || capabilities.canQuoteMessages else {
            throw ChatError.unsupported(capability: "quotedMessages")
        }
        guard formatting.count <= 1024, formatting.allSatisfy({ $0.range(in: text) != nil }),
              quote == nil || quote?.conversation == conversation else {
            throw ChatError.decoding("Invalid message content")
        }
    }
}

/// UTF-16 spans over the message text, using semantic style names.
public struct MessageFormat: Codable, Hashable, Sendable {
    public var style: String
    public var start: Int
    public var length: Int

    public init(style: String, start: Int, length: Int) {
        self.style = style
        self.start = start
        self.length = length
    }

    public func range(in text: String) -> Range<String.Index>? {
        guard start >= 0, length > 0, start <= text.utf16.count,
              length <= text.utf16.count - start else { return nil }
        guard let range = Range(NSRange(location: start, length: length), in: text),
              text.indices.contains(range.lowerBound),
              range.upperBound == text.endIndex || text.indices.contains(range.upperBound) else { return nil }
        return range
    }
}

/// An addressable quoted message. Identifiers remain opaque to clients.
public struct MessageQuote: Codable, Hashable, Sendable {
    public var id: Message.ID
    public var conversation: Conversation.ID
    public var thread: MessageThread.ID
    public var sender: Member.ID
    public var text: String
    public var createdAt: Date
    public var isDeleted: Bool

    public init(message: Message) {
        id = message.id
        conversation = message.conversationID
        thread = message.threadID
        sender = message.sender
        text = message.isDeleted ? "" : String(message.text.prefix(2000))
        createdAt = message.createdAt
        isDeleted = message.isDeleted
    }

    private enum CodingKeys: String, CodingKey {
        case id, conversation, thread, sender, text, createdAt, isDeleted
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Message.ID.self, forKey: .id)
        conversation = try container.decode(Conversation.ID.self, forKey: .conversation)
        thread = try container.decode(MessageThread.ID.self, forKey: .thread)
        sender = try container.decode(Member.ID.self, forKey: .sender)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try container.decodeWire(Date.self, forKey: .createdAt)
        isDeleted = try container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(conversation, forKey: .conversation)
        try container.encode(thread, forKey: .thread)
        try container.encode(sender, forKey: .sender)
        try container.encode(text, forKey: .text)
        try container.encodeWire(createdAt, forKey: .createdAt)
        try container.encode(isDeleted, forKey: .isDeleted)
    }
}
