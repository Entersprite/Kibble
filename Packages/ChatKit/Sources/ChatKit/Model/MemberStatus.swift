import Foundation

/// What someone says about themselves right now: an emoji, a line of text,
/// and when it stops being true - "🌴 On vacation until Friday".
///
/// Every field is optional because each genuinely is: a status can be an
/// emoji alone, text alone, or both, and most never expire. A struct of
/// optionals rather than an enum, so there is no discriminator to extend and
/// an older client simply ignores a key it does not know.
///
/// **`text` is user content.** It is shown and never logged, the same rule as
/// a message's text.
public struct MemberStatus: Codable, Hashable, Sendable {
    /// A Unicode emoji, drawn as text.
    public var emoji: String?
    /// A custom (uploaded image) emoji's shortcode, such as `:party-parrot:`.
    /// Its image is not carried: fetching it needs an authenticated URL that
    /// expires, so a client draws a stock glyph and shows the shortcode.
    public var customEmojiShortcode: String?
    public var text: String?
    /// `nil` means it does not expire. On the wire and in the store it is RFC
    /// 3339 to the **millisecond** (`RFC3339`), so a microsecond expiry from
    /// Google does not round-trip exactly. Nothing compares one against
    /// another, and nothing should be built that does.
    public var expiresAt: Date?

    public init(
        emoji: String? = nil,
        customEmojiShortcode: String? = nil,
        text: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.emoji = emoji
        self.customEmojiShortcode = customEmojiShortcode
        self.text = text
        self.expiresAt = expiresAt
    }

    /// Whether there is anything to draw.
    public var isEmpty: Bool {
        emoji == nil && customEmojiShortcode == nil && text == nil
    }
}

// MARK: - Coding

public extension MemberStatus {
    internal enum CodingKeys: String, CodingKey {
        case emoji
        case customEmojiShortcode
        case text
        case expiresAt
    }

    /// Hand-written so absent fields are omitted rather than written as
    /// `null`, and so `expiresAt` is RFC 3339 like every other date on the
    /// wire.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            emoji: container.decodeIfPresent(String.self, forKey: .emoji),
            customEmojiShortcode: container.decodeIfPresent(String.self, forKey: .customEmojiShortcode),
            text: container.decodeIfPresent(String.self, forKey: .text),
            expiresAt: container.decodeWireIfPresent(Date.self, forKey: .expiresAt)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(emoji, forKey: .emoji)
        try container.encodeIfPresent(customEmojiShortcode, forKey: .customEmojiShortcode)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeWireIfPresent(expiresAt, forKey: .expiresAt)
    }
}
