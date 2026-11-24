import Foundation

/// A message as the composer hands it over: the text to send and the mentions
/// inside it, spans in UTF-16 code units like every `Mention` (`findings.md`
/// §41.1). Also what a refused send hands back to the composer, so a resend
/// still mentions (mention composer spec §2).
///
/// Scheduled-message requests and responses carry this value directly.
public struct ComposedMessage: Codable, Hashable, Sendable {
    public var text: String
    public var mentions: [Mention]
    public var content: MessageContent?

    public init(text: String, mentions: [Mention] = [], content: MessageContent? = nil) {
        self.text = text
        self.mentions = mentions
        self.content = content?.isEmpty == true ? nil : content
    }

    private enum CodingKeys: String, CodingKey { case text, mentions, content }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            text: container.decode(String.self, forKey: .text),
            mentions: container.decodeIfPresent([Mention].self, forKey: .mentions) ?? [],
            content: container.decodeIfPresent(MessageContent.self, forKey: .content)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        if !mentions.isEmpty {
            try container.encode(mentions, forKey: .mentions)
        }
        try container.encodeIfPresent(content, forKey: .content)
    }
}
