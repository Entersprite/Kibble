import Foundation

/// A reaction summary: one emoji, and how many people used it.
///
/// A summary rather than a list of reactors. **[Verify]** the internal protocol
/// does appear to carry per-user reaction detail, but nothing in this repo has
/// confirmed what it contains under user authentication, and the public Chat
/// API exposes only a count. Modelling reactor identity now would mean
/// inventing a field no backend can fill, so `includesMe` carries the one piece
/// of identity a client actually needs — whether to draw the button as
/// selected.
///
/// Coding is synthesised. Every field is a scalar, there are no timestamps and
/// no default-on-absence decisions to make, so a hand-written coder would only
/// add a place for a future field to be forgotten. `CodingKeys` is spelled out
/// so the wire names are visible in the file that owns them.
public struct Reaction: Codable, Hashable, Sendable {
    public var emoji: String
    public var count: Int
    public var includesMe: Bool

    public init(emoji: String, count: Int, includesMe: Bool = false) {
        self.emoji = emoji
        self.count = count
        self.includesMe = includesMe
    }

    enum CodingKeys: String, CodingKey {
        case emoji
        case count
        case includesMe
    }
}
